# frozen_string_literal: true

module BulkDestroyer
  # Loads the dependent: :destroy graph below a batch of root records one level at a time:
  # one preload query per association per level, never per record.
  #
  # A record reachable by several paths is placed at its deepest level, so it is always deleted
  # before anything it references.
  class Tree
    def self.key_for(record)
      [record.class.base_class, record.id]
    end

    # +exclude+: keys of records that belong to an enclosing batch. Descendants found under them are
    # left alone (roots are always taken), so a nested pass never handles a record twice.
    def initialize(roots, exclude: nil)
      @roots = roots
      @exclude = exclude || Set.new
      @records = {}
      @depths = {}
    end

    # => Array of Arrays; index 0 holds the roots, higher indexes are deeper.
    def build
      frontier = []
      @roots.each { |root| add(root, 0, frontier) }

      until frontier.empty?
        current = frontier.uniq
        frontier = []
        current.group_by(&:class).each do |klass, owners|
          expand(klass, owners) do |child, owner, via|
            next if skipped?(child)

            canonical = add(child, @depths.fetch(key(owner)) + 1, frontier)
            canonical.destroyed_by_association = via if via
          end
        end
      end

      by_depth = Hash.new { |hash, depth| hash[depth] = [] }
      @records.each { |k, record| by_depth[@depths.fetch(k)] << record }
      by_depth.sort.map(&:last)
    end

    private

    def key(record)
      self.class.key_for(record)
    end

    def skipped?(record)
      k = key(record)
      !@records.key?(k) && @exclude.include?(k)
    end

    def add(record, depth, frontier)
      k = key(record)
      if (existing = @records[k])
        return existing if @depths.fetch(k) >= depth

        raise CycleDetected, "dependent: :destroy cycle detected at #{record.class.name}##{record.id}" if depth > @records.size

        @depths[k] = depth
        frontier << existing
        existing
      else
        @records[k] = record
        @depths[k] = depth
        frontier << record
        record
      end
    end

    def expand(klass, owners)
      plans = Dependents.plans_for(klass).select { |p| p.kind == :destroy || p.kind == :through_destroy }
      return if plans.empty?

      names = plans.map { |p| p.kind == :destroy ? p.reflection.name : p.reflection.through_reflection.name }.uniq
      ActiveRecord::Associations::Preloader.new(records: owners, associations: names).call

      plans.each do |plan|
        direct = plan.kind == :destroy
        name = direct ? plan.reflection.name : plan.reflection.through_reflection.name
        owners.each do |owner|
          Array(owner.association(name).target).each do |child|
            yield child, owner, (plan.reflection if direct)
          end
        end
      end
    end
  end
end
