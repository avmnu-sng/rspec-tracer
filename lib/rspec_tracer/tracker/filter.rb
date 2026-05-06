# frozen_string_literal: true

require 'set'

module RSpecTracer
  # Internal Tracker — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Tracker
    # Pure function that computes the filter result for a suite run:
    # given the previous dependency graph, the current change set,
    # the example registry, the whole-suite invalidation signal, and
    # the full list of example ids that exist this run, return the
    # Hash of {example_id => reason} for every example that must run.
    #
    # Stateless - every input is passed explicitly so the function is
    # trivial to unit-test, property-test, and use as a behavior-
    # parity target against 1.x's runner.rb.
    #
    # Precedence (first-match wins, highest to lowest):
    #
    #   1. :whole_suite_invalidator  - any watched file changed
    #      (Gemfile.lock, .ruby-version, .rspec-tracer, gem version)
    #      => every id in all_example_ids runs, no further checks.
    #   2. :interrupted              - example was killed mid-run
    #      on the previous run; always re-run.
    #   3. :flaky_example            - example was marked flaky; always
    #      re-run to re-observe.
    #   4. :failed_example           - previous failure; always re-run.
    #   5. :pending_example          - previous pending; always re-run.
    #   6. :no_cache                 - example exists this run but
    #      isn't in the graph (new example, never observed).
    #   7. :files_changed            - example's cached dependency
    #      set intersects the change_set.
    #
    # :skipped is deliberately not a reason - 1.x tracks skipped
    # examples for coverage attribution but does not re-run them.
    # ExampleRegistry#always_re_run_ids excludes :skipped; this
    # function mirrors that by iterating only the four re-run
    # statuses.
    module Filter
      # Internal constant.
      # @api private
      REASONS = %i[
        whole_suite_invalidator
        interrupted
        flaky_example
        failed_example
        pending_example
        no_cache
        files_changed
      ].freeze

      # Map from registry status to filter reason. Keyed in
      # precedence order so iteration preserves the precedence when
      # first-match wins in #assign_once.
      STATUS_TO_REASON = {
        interrupted: :interrupted,
        flaky: :flaky_example,
        failed: :failed_example,
        pending: :pending_example
      }.freeze

      # Internal helper for the tracer pipeline.
      # @api private
      def self.select(graph:, change_set:, registry:, whole_suite_invalidated:, all_example_ids:)
        ids = all_example_ids.to_set
        return whole_suite_result(ids) if whole_suite_invalidated

        result = {}
        add_always_re_run(result, registry, ids)
        add_new_examples(result, graph, ids)
        add_files_changed(result, graph, change_set, ids)
        result
      end

      # Convenience: Set<example_id> view of a select() result.
      def self.to_run_set(result)
        result.keys.to_set
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.whole_suite_result(ids)
        ids.to_h { |id| [id, :whole_suite_invalidator] }
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.add_always_re_run(result, registry, ids)
        STATUS_TO_REASON.each do |status, reason|
          registry.ids_with_status(status).each do |id|
            next unless ids.include?(id)

            assign_once(result, id, reason)
          end
        end
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.add_new_examples(result, graph, ids)
        known = graph.example_ids.to_set
        ids.each do |id|
          next if known.include?(id)

          assign_once(result, id, :no_cache)
        end
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.add_files_changed(result, graph, change_set, ids)
        graph.examples_depending_on(change_set).each do |id|
          next unless ids.include?(id)

          assign_once(result, id, :files_changed)
        end
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.assign_once(result, id, reason)
        result[id] ||= reason
      end
    end
  end
end
