# frozen_string_literal: true

module BulkDestroyer
  # Understands the `dependent:` options of ActiveRecord associations and reproduces their
  # semantics with set-based SQL.
  module Dependents
    Plan = Struct.new(:reflection, :kind)

    module_function

    # kinds: :destroy (children join the tree), :through_destroy (join records join the tree),
    #        :delete_all, :nullify, :restrict, :habtm (join rows are deleted without callbacks)
    def plans_for(klass)
      klass.reflect_on_all_associations.filter_map { |reflection| classify(reflection) }
    end

    def classify(reflection)
      return Plan.new(reflection, :habtm) if reflection.macro == :has_and_belongs_to_many

      dependent = reflection.options[:dependent]
      return nil if dependent.nil?

      if reflection.belongs_to?
        # Includes delegated_type, which declares `belongs_to ..., polymorphic: true, dependent: ...`.
        case dependent
        when :destroy then return Plan.new(reflection, :belongs_to_destroy)
        when :delete then return Plan.new(reflection, :belongs_to_delete)
        else unsupported!(reflection, "belongs_to with dependent: #{dependent.inspect} is not supported")
        end
      end

      through = reflection.options[:through]
      unsupported!(reflection, "nested has_many :through is not supported") if through && reflection.nested?

      case dependent
      when :destroy
        Plan.new(reflection, through ? :through_destroy : :destroy)
      when :delete_all, :delete
        Plan.new(reflection, :delete_all)
      when :nullify
        unsupported!(reflection, "dependent: :nullify on a :through association") if through
        Plan.new(reflection, :nullify)
      when :restrict_with_exception, :restrict_with_error
        Plan.new(reflection, :restrict)
      when :destroy_async
        unsupported!(reflection, "dependent: :destroy_async cannot be combined with bulk destroy")
      else
        unsupported!(reflection, "unknown dependent: #{dependent.inspect}")
      end
    end

    def unsupported!(reflection, message)
      raise UnsupportedAssociation, "#{reflection.active_record.name}##{reflection.name}: #{message}"
    end

    # Checks every restrict_with_* association before any hook runs.
    def check_restrictions!(records)
      records.group_by(&:class).each do |klass, owners|
        plans_for(klass).each do |plan|
          next unless plan.kind == :restrict

          reflection = plan.reflection
          source = reflection.options[:through] ? reflection.through_reflection : reflection
          owner_keys = owners.to_h { |o| [o._read_attribute(source.active_record_primary_key), o] }
          blocked = Set.new
          in_slices(owner_keys.keys, source.klass) do |keys|
            blocked.merge(child_relation(source, keys, owners.first).distinct.pluck(source.foreign_key))
          end
          next if blocked.empty?

          if reflection.options[:dependent] == :restrict_with_exception
            raise ActiveRecord::DeleteRestrictionError.new(reflection.name)
          end

          owner = owner_keys.fetch(blocked.first)
          human = owner.class.human_attribute_name(reflection.name).downcase
          owner.errors.add(:base, :"restrict_dependent_destroy.#{reflection.has_one? ? 'has_one' : 'has_many'}", record: human)
          raise ActiveRecord::RecordNotDestroyed.new("Failed to destroy #{owner.class.name}: #{owner.errors.full_messages.to_sentence}", owner)
        end
      end
    end

    # Targets of `belongs_to ..., dependent: :destroy / :delete` for one level of owners.
    # Rails destroys these inside the owner's after_destroy, i.e. once the owner's row is gone, so
    # Batch calls this after each level. Preloader loads them in one query per target class,
    # polymorphic included.
    #
    # +handled+ holds the keys of records already in (or already taken by) this batch; those are
    # skipped, and every target returned is added to it. That makes a target shared by several owners
    # come back once, and stops two models that point at each other from destroying each other forever.
    #
    # => { destroy: [records], delete: [records] }
    def belongs_to_targets(owners, handled)
      found = { destroy: [], delete: [] }
      owners.group_by(&:class).each do |klass, group|
        plans_for(klass).each do |plan|
          next unless plan.kind == :belongs_to_destroy || plan.kind == :belongs_to_delete

          name = plan.reflection.name
          ActiveRecord::Associations::Preloader.new(records: group, associations: [name]).call
          bucket = plan.kind == :belongs_to_destroy ? found[:destroy] : found[:delete]
          group.each do |owner|
            target = owner.association(name).target
            next if target.nil? || target.destroyed?
            next unless handled.add?(Tree.key_for(target))

            bucket << target
          end
        end
      end
      found
    end

    # :delete_all, :nullify and HABTM join rows for one level of the tree.
    # Rows removed by dependent: :delete_all are added to +counts+ under their model's base class name
    # (HABTM join rows are not counted: the join table has no model of its own).
    def apply_bulk_operations(records, counts)
      records.group_by(&:class).each do |klass, owners|
        plans_for(klass).each do |plan|
          reflection = plan.reflection
          case plan.kind
          when :delete_all
            source = reflection.options[:through] ? reflection.through_reflection : reflection
            each_child_relation(source, owners) do |relation|
              deleted = relation.delete_all
              counts[source.klass.base_class.name] += deleted if deleted.positive?
            end
          when :nullify
            attributes = { reflection.foreign_key => nil }
            attributes[reflection.type] = nil if reflection.type
            each_child_relation(reflection, owners) { |relation| relation.update_all(attributes) }
          when :habtm
            middle = klass._reflections.values.find { |r| r.parent_reflection.equal?(reflection) && r.options[:through].nil? }
            each_child_relation(middle, owners) { |relation| relation.delete_all }
          end
        end
      end
    end

    def each_child_relation(reflection, owners)
      keys = owners.map { |o| o._read_attribute(reflection.active_record_primary_key) }
      in_slices(keys, reflection.klass) do |slice|
        yield child_relation(reflection, slice, owners.first)
      end
    end

    # Rows that belong to +owner_keys+ through +reflection+, honouring the association scope,
    # custom keys, and polymorphic `as:` type columns.
    def child_relation(reflection, owner_keys, sample_owner)
      if Array(reflection.foreign_key).size > 1
        unsupported!(reflection, "composite foreign keys are only supported for dependent: :destroy")
      end

      relation = reflection.klass.all
      if reflection.scope
        if reflection.scope.arity.positive?
          unsupported!(reflection, "instance-dependent association scopes are only supported for dependent: :destroy")
        end
        relation = relation.instance_exec(&reflection.scope)
      end
      relation = relation.where(reflection.foreign_key => owner_keys)
      relation = relation.where(reflection.type => sample_owner.class.polymorphic_name) if reflection.type
      relation
    end

    # Splits long IN lists to stay below adapter limits (Oracle 1000, SQL Server ~2100, ...).
    def in_slices(values, model, &block)
      limit = BulkDestroyer.in_list_size_for(model)
      values.each_slice(limit, &block)
    end
  end
end
