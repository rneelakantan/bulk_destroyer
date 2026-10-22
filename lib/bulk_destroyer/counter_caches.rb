# frozen_string_literal: true

module BulkDestroyer
  # Rails decrements belongs_to counter caches inside Persistence#destroy_row, which bulk
  # deletion bypasses. This reproduces it with one UPDATE per (counter column, amount) rather
  # than one per row.
  module CounterCaches
    module_function

    # Rails 7.2+ exposes counter_cached_association_names; 7.1 only has the reflections.
    def counter_cached_reflections(klass)
      if klass.respond_to?(:counter_cached_association_names)
        klass.counter_cached_association_names.map { |name| klass._reflect_on_association(name) }
      else
        klass.reflect_on_all_associations(:belongs_to).select(&:counter_cache_column)
      end
    end

    def decrement(records)
      records.group_by(&:class).each do |klass, group|
        counter_cached_reflections(klass).each do |reflection|
          name = reflection.name
          simple = !reflection.polymorphic? && Array(reflection.foreign_key).size == 1
          tally = Hash.new(0)

          group.each do |record|
            # Same rule as Rails: a child destroyed via its parent's dependent: association does
            # not touch that parent's counter.
            via = record.destroyed_by_association
            next if via && via.foreign_key == reflection.foreign_key

            if simple
              id = record._read_attribute(reflection.foreign_key)
              tally[id] += 1 if id
            else
              record.association(name).decrement_counters
            end
          end

          tally.group_by { |_id, n| n }.each do |n, pairs|
            counters = { reflection.counter_cache_column => -n }
            counters[:touch] = reflection.options[:touch] if reflection.options[:touch]
            Dependents.in_slices(pairs.map(&:first), reflection.klass) do |ids|
              reflection.klass.update_counters(ids.sort, counters.dup)
            end
          end
        end
      end
    end
  end
end
