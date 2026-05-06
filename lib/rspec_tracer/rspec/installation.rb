# frozen_string_literal: true

require 'rspec/core'

require_relative 'reporter_hook'
require_relative 'runner_hook'

module RSpecTracer
  module RSpec
    # Prepends RunnerHook + ReporterHook onto RSpec's runner/reporter
    # classes. Called once from `RSpecTracer.start`.
    #
    # 1.x used `ObjectSpace.each_object(::RSpec::Core::Runner)` to find
    # the already-instantiated runner and prepend onto its singleton
    # class - forcing start-time ordering (RSpec had to be mid-boot).
    # 2.0 prepends onto the class itself at require time, so the hooks
    # apply to every subsequent Runner / Reporter instance.
    #
    # Consequence: `RSpecTracer.start` no longer requires RSpec to be
    # running. As long as `RSpec::Core::Runner` and `RSpec::Core::Reporter`
    # are loaded (the standard `require 'rspec'` in spec_helper covers
    # both), install! succeeds. Side effect: the JRuby FULL_TRACE_ENABLED
    # / object_space_enabled guard that 1.x needed is no longer load-
    # bearing - prepend doesn't touch ObjectSpace.
    #
    # Idempotence: `Module#prepend` is a no-op when the module is already
    # in the ancestors chain. Double-calling install! is safe.
    module Installation
      # `install!` is named for its side effect (prepend the hooks), not
      # as a predicate - rubocop's Naming/PredicateMethod defaults to
      # flagging anything that doesn't return a boolean, but the trailing
      # `true` is the Ruby idiom for "side-effect method ran fine".
      #
      # Target classes are parameterized so unit specs can pass anonymous
      # fresh classes instead of stubbing the real RSpec constants - the
      # latter collides with RSpec's own reporter finalization at at_exit
      # time (RSpec::Core::Time vanishes while the outer suite is still
      # finalizing).
      # rubocop:disable Naming/PredicateMethod
      def self.install!(runner_class: ::RSpec::Core::Runner, reporter_class: ::RSpec::Core::Reporter)
        warn_if_coverage_already_accumulated

        prepend_hook(runner_class, RSpecTracer::RSpec::RunnerHook)
        prepend_hook(reporter_class, RSpecTracer::RSpec::ReporterHook)

        true
      end
      # rubocop:enable Naming/PredicateMethod

      def self.prepend_hook(target_class, hook_module)
        return if target_class.ancestors.include?(hook_module)

        target_class.prepend(hook_module)
      end

      # Emit a single warn-level line when the user's spec_helper
      # triggered substantial application-code loads before calling
      # `RSpecTracer.start`. The Coverage peek_result is per-file; we
      # count files that already have at least one executed line. A
      # non-SimpleCov fresh boot with >10 tracked files is the signal
      # that app code loaded before the tracer started, which means
      # boot-set capture misses those files as transitive dependencies.
      #
      # Conservative by design: skip the warning when SimpleCov is
      # running (SimpleCov-first is the documented load order), and
      # when Coverage hasn't started (defended-library edge case).
      def self.warn_if_coverage_already_accumulated
        return unless defined?(::Coverage)
        return unless ::Coverage.respond_to?(:running?) && ::Coverage.running?
        return if defined?(::SimpleCov) && ::SimpleCov.running

        accumulated = _count_accumulated_files
        return if accumulated < 10

        RSpecTracer.logger.warn(
          "RSpec tracer: coverage has already accumulated for #{accumulated} file(s) " \
          'before RSpecTracer.start. Expected load order: RSpecTracer.start runs before ' \
          'any application code (or after SimpleCov.start if using SimpleCov). Dependency ' \
          'attribution may miss boot-time loads.'
        )
      rescue StandardError
        nil
      end

      def self._count_accumulated_files
        ::Coverage.peek_result.count do |_, cov|
          lines = cov.is_a?(::Hash) ? cov[:lines] : cov
          lines.is_a?(::Array) && lines.any? { |strength| strength.is_a?(::Integer) && strength.positive? }
        end
      end
    end
  end
end
