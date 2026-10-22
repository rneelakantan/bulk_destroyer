# frozen_string_literal: true

module BulkDestroyer
  # Runs a record's real :destroy callback chain in two halves around the bulk DELETE.
  #
  # FiberRunner: each record's `run_callbacks(:destroy)` runs inside a Fiber whose block yields.
  #   - start(record)  runs before_destroy and the first half of around_destroy, up to the block
  #   - finish(record) resumes it after the rows are gone: second half of around_destroy, then
  #                    after_destroy. Conditions (if:/unless:), ordering, prepend:, callback
  #                    objects and `throw :abort` are all handled by Rails itself.
  #
  # InlineRunner: runs the whole chain before the DELETE (after_destroy sees the row). Only for
  #   apps running with ActiveSupport::IsolatedExecutionState.isolation_level = :fiber.
  module HookRunner
    def self.build(mode: BulkDestroyer.hook_mode)
      case mode
      when :fiber
        if ActiveSupport::IsolatedExecutionState.isolation_level == :fiber
          raise UnsupportedIsolation,
                "isolation_level is :fiber, so each hook Fiber would get its own database connection. " \
                "Set BulkDestroyer.hook_mode = :inline (after_destroy then runs just before the DELETE)."
        end
        FiberRunner.new
      when :inline then InlineRunner.new
      else raise ArgumentError, "unknown hook_mode #{mode.inspect}"
      end
    end

    class FiberRunner
      def initialize
        @fibers = {}.compare_by_identity
        # Thread.current[] values are fiber-local; copy them so hooks that read request-scoped
        # state (RequestStore-style) see the same values inside the hook fibers.
        @locals = Thread.current.keys.reject { |k| k.to_s.start_with?("__") }.to_h { |k| [k, Thread.current[k]] }
      end

      # => true when the chain reached the destroy step, false when a before_destroy halted it.
      def start(record)
        locals = @locals
        fiber = Fiber.new do
          locals.each { |k, v| Thread.current[k] = v }
          record.run_callbacks(:destroy) do
            Fiber.yield(:ready)
            true
          end
        end
        @fibers[record] = fiber
        fiber.resume
        return true if fiber.alive?

        @fibers.delete(record)
        false
      end

      def finish(record)
        fiber = @fibers.delete(record)
        fiber&.resume
      end

      # Unwinds fibers still suspended after a failure so around_destroy `ensure` blocks run.
      def abort_all
        @fibers.each_value do |fiber|
          next unless fiber.alive?

          begin
            fiber.raise(Unwind)
          rescue Unwind, StandardError
            nil
          end
        end
        @fibers.clear
      end
    end

    class InlineRunner
      def start(record)
        record.run_callbacks(:destroy) { true } ? true : false
      end

      def finish(_record); end

      def abort_all; end
    end
  end
end
