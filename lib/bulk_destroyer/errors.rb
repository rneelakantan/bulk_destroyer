# frozen_string_literal: true

module BulkDestroyer
  class Error < StandardError; end

  # An association configuration the gem cannot reproduce faithfully
  # (e.g. belongs_to dependent:, :destroy_async, composite-key :nullify).
  class UnsupportedAssociation < Error; end

  # ActiveSupport::IsolatedExecutionState.isolation_level == :fiber and hook_mode == :fiber.
  class UnsupportedIsolation < Error; end

  # The dependent: :destroy graph contains a cycle in the data.
  class CycleDetected < Error; end

  # One root's dependent: :destroy tree has more hook-bearing records than BulkDestroyer.max_batch_records
  # and cannot be split any further (see BulkDestroyer.oversized_tree).
  class TreeTooLarge < Error; end

  # Internal: a batch with several roots built a tree over the limit before running any hook; the caller
  # retries with the roots split in two. Never reaches application code.
  class SplitRequired < Error; end

  # Raised inside suspended hook fibers to unwind them (so `ensure` blocks in around_destroy
  # callbacks run). Deliberately not a StandardError so `rescue => e` in app hooks can't swallow it.
  class Unwind < Exception; end # rubocop:disable Lint/InheritException
end
