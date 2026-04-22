# frozen_string_literal: true

module RSpecTracer
  module Reporters
    # Abstract base for every reporter M6.1 / M6.2 ships. Takes the
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
    class Base
      attr_reader :snapshot, :report_dir, :run_metadata, :logger, :options

      def initialize(snapshot:, report_dir:, run_metadata:, logger: nil, **options)
        @snapshot = snapshot
        @report_dir = report_dir
        @run_metadata = run_metadata || {}
        @logger = logger
        @options = options
      end

      def generate
        raise NotImplementedError, "#{self.class}#generate must be implemented"
      end

      def no_op?
        snapshot.nil? ||
          snapshot.all_examples.nil? ||
          snapshot.all_examples.empty?
      end
    end
  end
end
