# frozen_string_literal: true

module RSpecTracer
  module Reporters
    # Orchestrates reporter emission at finalize-time. Called from
    # `RSpecTracer#run_exit_tasks` once the Engine has persisted its
    # Snapshot (architectural decision (a): wire from run_exit_tasks,
    # not Engine-internal). Each configured reporter gets an isolated
    # rescue; a buggy reporter warns + continues, never propagates a
    # non-zero exit into the user's test suite.
    #
    # Reporter resolution:
    #   - Configuration#reporters returns `[[name_or_class, opts], ...]`
    #     when the user called `add_reporter`; `nil` otherwise.
    #   - When nil, falls back to `DEFAULTS` (`[:terminal, :json]`).
    #   - Symbol names resolve via `BUILT_INS` to in-tree reporter
    #     classes. Class values pass through as-is (custom reporters
    #     conforming to `Reporters::Base`).
    #   - Unknown symbols raise `ArgumentError` at emit time; the DSL
    #     validates eagerly, so this is the safety net for programmatic
    #     callers.
    class Registry
      # Symbol -> lazy class-name mapping. Strings (not Class constants)
      # so the require order doesn't force load of reporter classes
      # when the Registry module itself is loaded - matches how
      # `storage_backend`'s Configuration DSL defers backend resolution.
      BUILT_INS = {
        terminal: 'RSpecTracer::Reporters::TerminalReporter',
        json: 'RSpecTracer::Reporters::JsonReporter',
        html: 'RSpecTracer::Reporters::HtmlReporter'
      }.freeze

      DEFAULTS = %i[terminal json html].freeze

      def self.emit_all(configuration:, snapshot:, report_dir:, run_metadata:)
        new(configuration: configuration).emit_all(
          snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata
        )
      end

      def initialize(configuration:)
        @configuration = configuration
      end

      def emit_all(snapshot:, report_dir:, run_metadata:)
        entries = resolve_entries
        return [] if entries.empty?
        return [] if empty_snapshot?(snapshot)

        entries.map { |klass, opts| emit_one(klass, opts, snapshot, report_dir, run_metadata) }
      end

      private

      def resolve_entries
        declared = @configuration.respond_to?(:reporters) ? @configuration.reporters : nil
        source = declared && !declared.empty? ? declared : DEFAULTS.map { |name| [name, {}] }
        source.map { |name_or_class, opts| [resolve_class(name_or_class), opts || {}] }
      end

      def resolve_class(name_or_class)
        return name_or_class if name_or_class.is_a?(Class)

        const_name = BUILT_INS.fetch(name_or_class) do
          raise ArgumentError, "unknown reporter: #{name_or_class.inspect}"
        end

        Object.const_get(const_name)
      end

      def emit_one(klass, opts, snapshot, report_dir, run_metadata)
        reporter = klass.new(
          snapshot: snapshot,
          report_dir: report_dir,
          run_metadata: run_metadata,
          logger: logger,
          **opts
        )
        reporter.generate
      rescue StandardError => e
        warn_continue(klass, e)
        nil
      end

      def warn_continue(klass, err)
        logger&.warn("rspec-tracer: reporter #{klass.name} failed (#{err.class}: #{err.message})")
      end

      def logger
        @configuration.respond_to?(:logger) ? @configuration.logger : nil
      end

      def empty_snapshot?(snapshot)
        snapshot.nil? || snapshot.all_examples.nil? || snapshot.all_examples.empty?
      end
    end
  end
end
