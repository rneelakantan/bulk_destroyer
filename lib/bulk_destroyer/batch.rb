# frozen_string_literal: true

module BulkDestroyer
  # One transaction's worth of work: a batch of root records and everything below them.
  #
  #   1. Tree          load the dependent: :destroy graph (one query per association per level)
  #   2. restrictions  dependent: :restrict_with_* checked before anything runs
  #   3. start hooks   before_destroy / first half of around_destroy, parents before children
  #   4. per level, deepest first:
  #        nullify / delete_all / HABTM join rows  ->  bulk DELETE  ->  counter caches
  #        ->  mark records destroyed  ->  after_destroy / second half of around_destroy
  #
  # Level-by-level means a child's after_destroy runs while its parent row still exists, and a
  # parent's after_destroy runs after its children are gone, as with plain `destroy`.
  class Batch
    def initialize(roots, handled: Set.new)
      @roots = roots
      @handled = handled
    end

    def run
      levels = Tree.new(@roots, exclude: @handled).build
      records = levels.flatten
      inline = oversized?(records) # raises before anything ran if the tree is too big for Fibers
      records.each { |record| @handled << Tree.key_for(record) }
      counts = Hash.new(0)
      runner = nil

      begin
        Dependents.check_restrictions!(records)
        runner = HookRunner.build(mode: inline ? :inline : BulkDestroyer.hook_mode)
        records.each { |record| prepare(record) }
        levels.flatten.each do |record|
          next if runner.start(record)

          raise ActiveRecord::RecordNotDestroyed.new("Failed to destroy #{record.class.name} with #{record.class.primary_key}=#{record.id}", record)
        end

        levels.reverse_each do |level|
          Dependents.apply_bulk_operations(level, counts)
          delete_rows(level, counts)
          CounterCaches.decrement(level)
          level.each { |record| mark_destroyed(record) }
          level.each { |record| runner.finish(record) }
          destroy_belongs_to_targets(level, counts)
        end
      ensure
        runner&.abort_all
        records.each { |record| record.remove_instance_variable(CascadeGuard::FLAG) if record.instance_variable_defined?(CascadeGuard::FLAG) }
      end

      counts
    end

    private

    # belongs_to ..., dependent: :destroy / :delete. Rails does this in the owner's after_destroy; here it
    # happens once the whole level of owners is gone. :destroy targets go through a nested Batch (their own
    # hooks, children, restrictions and further belongs_to targets), still inside this transaction.
    def destroy_belongs_to_targets(level, counts)
      found = Dependents.belongs_to_targets(level, @handled)

      run_nested(found[:destroy], counts) unless found[:destroy].empty?

      found[:delete].group_by { |target| target.class.base_class }.each do |base, group|
        ids = sortable(group.map(&:id))
        Dependents.in_slices(ids, base) do |slice|
          deleted = base.unscoped.where(base.primary_key => slice).delete_all
          counts[base.name] += deleted if deleted.positive?
        end
        # Same end state as Rails' #delete: marked destroyed, no callbacks, no commit hooks.
        group.each do |target|
          target.instance_variable_set(:@destroyed, true)
          target.freeze
        end
      end
    end

    # Same transaction as the enclosing batch. A tree that is too big for Fibers is split by targets.
    def run_nested(targets, counts)
      Batch.new(targets, handled: @handled).run.each { |name, n| counts[name] += n }
    rescue SplitRequired
      middle = targets.size / 2
      run_nested(targets.first(middle), counts)
      run_nested(targets.drop(middle), counts)
    end

    # One paused Fiber per record, all alive at once, so the tree size is capped. => true when this batch
    # has to run its hooks without Fibers.
    def oversized?(records)
      return false if BulkDestroyer.hook_mode == :inline
      return false if records.size <= BulkDestroyer.max_batch_records
      raise SplitRequired if @roots.size > 1

      case BulkDestroyer.oversized_tree
      when :inline then true
      when :raise
        raise TreeTooLarge,
              "the dependent: :destroy tree below #{@roots.first.class.name}##{@roots.first.id} has " \
              "#{records.size} records with destroy hooks, more than BulkDestroyer.max_batch_records " \
              "(#{BulkDestroyer.max_batch_records}). Each needs a paused Fiber and Ruby on Linux fails around " \
              "31,000. Raise max_batch_records (keep it well below that), or set " \
              "BulkDestroyer.oversized_tree = :inline to run these hooks without Fibers " \
              "(after_destroy then runs before the DELETE)."
      else raise ArgumentError, "unknown oversized_tree #{BulkDestroyer.oversized_tree.inspect}"
      end
    end

    def prepare(record)
      record.instance_variable_set(CascadeGuard::FLAG, true)
      record.send(:_raise_readonly_record_error) if record.readonly?
      # Same bookkeeping Rails' with_transaction_returning_status does for a normal destroy: it
      # lets after_commit / after_rollback fire and restores @destroyed if the batch rolls back.
      record.send(:add_to_transaction)
      record.send(:remember_transaction_record_state)
    end

    def delete_rows(level, counts)
      level.group_by { |record| record.class.base_class }.each do |base, group|
        ids = sortable(group.map(&:id))
        base.transaction do
          Dependents.in_slices(ids, base) do |slice|
            counts[base.name] += base.unscoped.where(base.primary_key => slice).delete_all
          end
        end
      end
    end

    # Ascending ids give concurrent bulk deletes a consistent lock order (fewer deadlocks).
    def sortable(ids)
      ids.sort
    rescue ArgumentError, NoMethodError
      ids
    end

    def mark_destroyed(record)
      record.instance_variable_set(:@_trigger_destroy_callback, true)
      record.instance_variable_set(:@destroyed, true)
      record.instance_variable_set(:@previously_new_record, false)
      record.freeze
    end
  end
end
