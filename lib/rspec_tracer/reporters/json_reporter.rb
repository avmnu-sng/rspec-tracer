# frozen_string_literal: true

require 'fileutils'
require 'json'

require_relative 'base'
require_relative 'payload_builder'

module RSpecTracer
  # Internal Reporters — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Reporters
    # Machine-readable summary of a tracer run. Writes
    # `<report_dir>/report.json` containing a stable, schema-versioned
    # envelope around the 5 report types that 1.x's HTML reporter
    # surfaced (All, Duplicate, Flaky, Examples Dependency, Files
    # Dependency) plus a run summary block.
    #
    # Payload shape lives in `PayloadBuilder` (shared with
    # `HtmlReporter` so the two never drift). Schema contract docs for
    # version 1:
    #
    #   {
    #     "schema_version": 1,
    #     "run_id": <hex md5 of sorted example ids>,
    #     "generated_at": <ISO-8601 UTC timestamp at emit time>,
    #     "summary": {
    #       "total_examples": <Integer>,
    #       "passed_examples": <Integer>,
    #       "failed_examples": <Integer>,
    #       "pending_examples": <Integer>,
    #       "skipped_examples": <Integer>,
    #       "interrupted_examples": <Integer>,
    #       "flaky_examples": <Integer>,
    #       "duplicate_examples": <Integer>,
    #       "tracked_env_keys": <Integer>,
    #       "run_time": <Float|null>,
    #       "started_at": <ISO-8601|null>,
    #       "pid": <Integer|null>,
    #       "parallel_tests": <Boolean>
    #     },
    #     "reports": {
    #       "all_examples": [ {id, description, location, status, run_reason, execution_result}, ... ],
    #       "duplicate_examples": [ {id, count, entries: [{description, location}, ...]}, ... ],
    #       "flaky_examples": [ {id, description, location}, ... ],
    #       "examples_dependency": [ {example_id, files: [...], env_keys: [...]}, ... ],
    #       "files_dependency": [ {file_name, example_count, spec_files: {path => count}}, ... ]
    #     }
    #   }
    #
    # Breaking schema changes bump `SCHEMA_VERSION`. Additive fields
    # (new keys in an existing object) are NOT breaking. Removed or
    # renamed keys ARE. Downstream consumers (HTML reporter, user CI
    # dashboards) should branch on the top-level version.
    class JsonReporter < Base
      # Internal constant.
      # @api private
      SCHEMA_VERSION = PayloadBuilder::SCHEMA_VERSION
      # Internal constant.
      # @api private
      FILENAME = 'report.json'

      # Concrete implementation of {RSpecTracer::Reporters::Base#generate}.
      # Serializes the canonical payload via {PayloadBuilder} and writes
      # `report.json` under {#report_dir}.
      #
      # @return [String, nil] absolute path of the written file, or nil
      #   when the run had no examples to report.
      def generate
        return nil if no_op?

        FileUtils.mkdir_p(report_dir)
        path = File.join(report_dir, FILENAME)
        File.write(path, JSON.pretty_generate(build_payload), encoding: 'UTF-8')
        logger&.debug("rspec-tracer: wrote report JSON to #{path}")
        path
      end

      private

      # Internal method on the tracer pipeline.
      # @api private
      def build_payload
        PayloadBuilder.build(snapshot: snapshot, run_metadata: run_metadata)
      end
    end
  end
end
