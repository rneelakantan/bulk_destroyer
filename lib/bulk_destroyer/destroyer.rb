# frozen_string_literal: true

module BulkDestroyer
  class Destroyer
    def initialize(source, batch_size: BulkDestroyer.batch_size)
      @source = source
      @batch_size = Integer(batch_size)
      raise ArgumentError, "batch_size must be positive" unless @batch_size.positive?
    end

    # => { "Post" => 3, "Comment" => 12, ... } rows deleted per table (by base class name)
    def call
      counts = Hash.new(0)
      each_root_batch { |roots| run_roots(roots, counts) }
      counts.to_h
    end

    private

    def run_roots(roots, counts)
      # requires_new: a failing batch rolls back to its own savepoint (inside a caller's
      # transaction) or its own real transaction (outside one).
      completed = false
      roots.first.class.transaction(requires_new: true) do
        Batch.new(roots).run.each { |name, n| counts[name] += n }
        completed = true
      end

      # `transaction` swallows ActiveRecord::Rollback: it rolls the batch back and returns nil without
      # raising. A hook that does that would otherwise make this batch vanish silently.
      return if completed

      raise ActiveRecord::RecordNotDestroyed.new(
        "bulk destroy rolled back a batch of #{roots.size} #{roots.first.class.name} record(s): " \
        "ActiveRecord::Rollback was raised in a destroy callback",
        roots.first
      )
    rescue SplitRequired
      # The tree under these roots has too many records for one batch of paused Fibers. Nothing ran yet
      # (the savepoint is already rolled back); do each half as its own batch.
      middle = roots.size / 2
      run_roots(roots.first(middle), counts)
      run_roots(roots.drop(middle), counts)
    end

    def each_root_batch(&block)
      case @source
      when ActiveRecord::Base
        yield [@source] if @source.persisted?
      when ActiveRecord::Relation
        @source.find_in_batches(batch_size: @batch_size, &block)
      else
        raise ArgumentError, "expected an ActiveRecord relation or record, got #{@source.class}"
      end
    end
  end
end
