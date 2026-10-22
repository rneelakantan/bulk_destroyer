# frozen_string_literal: true

require "set"
require "active_support"
require "active_record"

require_relative "bulk_destroyer/version"
require_relative "bulk_destroyer/errors"
require_relative "bulk_destroyer/cascade_guard"
require_relative "bulk_destroyer/dependents"
require_relative "bulk_destroyer/tree"
require_relative "bulk_destroyer/hook_runner"
require_relative "bulk_destroyer/counter_caches"
require_relative "bulk_destroyer/batch"
require_relative "bulk_destroyer/destroyer"
require_relative "bulk_destroyer/api"

module BulkDestroyer
  # Hard ceilings for IN (...) lists by adapter; the effective size is min(in_list_size, ceiling).
  ADAPTER_IN_LIMITS = {
    "oracleenhanced" => 1_000,
    "sqlserver" => 2_000,
    "sqlite" => 32_766
  }.freeze
  DEFAULT_IN_LIMIT = 65_000

  class << self
    # Parents loaded per transaction.
    attr_accessor :batch_size
    # Max values per `WHERE id IN (...)` chunk.
    attr_accessor :in_list_size
    # :fiber (default; after_destroy runs after the DELETE) or :inline (see HookRunner).
    attr_accessor :hook_mode
    # Most records (with destroy hooks) one batch may hold. :fiber mode keeps one paused Fiber per record,
    # and Ruby on Linux fails (FiberError) at roughly 31,000 live Fibers with the default vm.max_map_count.
    # A batch whose tree is larger is split in half until it fits; keep this well below that ceiling,
    # because nested belongs_to target batches are counted separately.
    attr_accessor :max_batch_records
    # What to do when ONE root's tree alone exceeds max_batch_records: :raise (default, TreeTooLarge)
    # or :inline (run that batch's hooks without Fibers, so its after_destroy hooks run before the DELETE).
    attr_accessor :oversized_tree

    def in_list_size_for(model)
      # Model.with_connection arrived in Rails 7.2; 7.1 only has Model.connection.
      name = model.respond_to?(:with_connection) ? model.with_connection(&:adapter_name) : model.connection.adapter_name
      adapter = name.to_s.downcase.delete("_ ")
      ceiling = ADAPTER_IN_LIMITS.find { |name, _| adapter.include?(name) }&.last || DEFAULT_IN_LIMIT
      [in_list_size, ceiling].min
    end
  end

  self.batch_size = 1_000
  self.in_list_size = 500
  self.hook_mode = :fiber
  self.max_batch_records = 10_000
  self.oversized_tree = :raise
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::Relation.include BulkDestroyer::RelationMethods
  ActiveRecord::Base.extend BulkDestroyer::ClassMethods
  ActiveRecord::Base.include BulkDestroyer::RecordMethods

  [ActiveRecord::Associations::HasManyAssociation,
   ActiveRecord::Associations::HasOneAssociation,
   ActiveRecord::Associations::BelongsToAssociation].each do |association|
    association.prepend BulkDestroyer::CascadeGuard
  end
end
