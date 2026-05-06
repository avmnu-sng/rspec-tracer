# frozen_string_literal: true

module RSpecTracer
  module Reporters
    # Abstract base for every reporter rspec-tracer ships. Takes the
    # finalized Storage::Snapshot + report_dir + run_metadata triplet
    # (architectural decision (b), Option X - raw Snapshot, no
    # projection struct) and exposes two lifecycle hooks:
    #
    #   - `generate` - subclass must implement; emits the reporter's
    #     output format (JSON file, terminal lines, HTML etc.)
    #   - `no_op?` - true when the run had zero tracked examples; the
    #     Registry checks this before calling `generate` so empty runs
    #     don't litter the report_dir with empty artifacts.
    #
    # `initialize` accepts `**opts` so custom reporters can take
    # constructor args via `config.add_reporter MyReporter, color: false`.
    # The base class itself ignores opts; subclasses read what they need.
    #
    # Errors during `generate` are NOT rescued here - the Registry
    # wraps each reporter call in a per-reporter rescue + warn, so a
    # buggy custom reporter never propagates a non-zero exit into the
    # user's test suite (graceful degradation, same contract as
    # Storage backends per ARCHITECTURE.md).
    #
    # @example Registering a custom reporter
    #   class MyReporter < RSpecTracer::Reporters::Base
    #     def generate
    #       File.write(File.join(report_dir, 'my.json'),
    #                  JSON.pretty_generate(snapshot.to_h))
    #     end
    #   end
    #
    #   RSpecTracer.configure do
    #     add_reporter MyReporter, my_option: true
    #   end
    class Base
      attr_reader :snapshot, :report_dir, :run_metadata, :logger, :options

      # @param snapshot [RSpecTracer::Storage::Snapshot] the finalized
      #   per-run snapshot (`nil` only on early-abort paths)
      # @param report_dir [String] absolute path the reporter should
      #   write into (created by Engine.finalize before this fires)
      # @param run_metadata [Hash] pid / run_time / started_at /
      #   cache_path / parallel_tests / rails flags
      # @param logger [#info, #warn, nil] tracer logger
      # @param options [Hash] reporter-specific keyword args from
      #   `add_reporter MyReporter, **opts`
      def initialize(snapshot:, report_dir:, run_metadata:, logger: nil, **options)
        @snapshot = snapshot
        @report_dir = report_dir
        @run_metadata = run_metadata || {}
        @logger = logger
        @options = options
      end

      # Subclass must implement. Called once per reporter per run by
      # the Registry. Errors propagate to the Registry's per-reporter
      # rescue (graceful degradation: a buggy reporter never breaks
      # the suite).
      #
      # @return [void]
      def generate
        raise NotImplementedError, "#{self.class}#generate must be implemented"
      end

      # Registry skips `generate` when this returns true so empty runs
      # do not produce empty artifacts.
      #
      # @return [Boolean]
      def no_op?
        snapshot.nil? ||
          snapshot.all_examples.nil? ||
          snapshot.all_examples.empty?
      end
    end
  end
end
