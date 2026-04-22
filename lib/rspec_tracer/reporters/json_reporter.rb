# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'
require 'time'

require_relative 'base'

module RSpecTracer
  module Reporters
    # Machine-readable summary of a tracer run. Writes
    # `<report_dir>/report.json` containing a stable, schema-versioned
    # envelope around the 5 report types that 1.x's HTML reporter
    # surfaced (All, Duplicate, Flaky, Examples Dependency, Files
    # Dependency) plus a run summary block.
    #
    # Schema contract (version 1, M6.1):
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
    # renamed keys ARE. Downstream consumers (HTML reporter in M6.2,
    # user CI dashboards) should branch on the top-level version.
    class JsonReporter < Base
      SCHEMA_VERSION = 1
      FILENAME = 'report.json'

      def generate
        return nil if no_op?

        FileUtils.mkdir_p(report_dir)
        path = File.join(report_dir, FILENAME)
        File.write(path, JSON.pretty_generate(build_payload), encoding: 'UTF-8')
        logger&.debug("rspec-tracer: wrote report JSON to #{path}")
        path
      end

      private

      def build_payload
        {
          schema_version: SCHEMA_VERSION,
          run_id: snapshot.run_id,
          generated_at: Time.now.utc.iso8601,
          summary: summary_block,
          reports: {
            all_examples: all_examples_report,
            duplicate_examples: duplicate_examples_report,
            flaky_examples: flaky_examples_report,
            examples_dependency: examples_dependency_report,
            files_dependency: files_dependency_report
          }
        }
      end

      def summary_block
        {
          total_examples: snapshot.all_examples.size,
          passed_examples: count_status(:passed),
          failed_examples: snapshot.failed_examples.size,
          pending_examples: snapshot.pending_examples.size,
          skipped_examples: snapshot.skipped_examples.size,
          interrupted_examples: snapshot.interrupted_examples.size,
          flaky_examples: snapshot.flaky_examples.size,
          duplicate_examples: snapshot.duplicate_examples.size,
          tracked_env_keys: (snapshot.env_snapshot || {}).size,
          run_time: run_metadata[:run_time],
          started_at: stringify_time(run_metadata[:started_at]),
          pid: run_metadata[:pid],
          parallel_tests: run_metadata[:parallel_tests] == true
        }
      end

      def count_status(status)
        status_str = status.to_s
        snapshot.all_examples.count do |_, meta|
          next false unless meta.is_a?(::Hash)

          result = meta[:execution_result] || meta['execution_result']
          next false unless result.is_a?(::Hash)

          (result[:status] || result['status']).to_s == status_str
        end
      end

      def all_examples_report
        snapshot.all_examples.map do |id, meta|
          meta = {} unless meta.is_a?(::Hash)
          {
            id: id,
            description: meta[:full_description] || meta[:description],
            location: location_for(meta),
            status: status_for(id, meta),
            run_reason: meta[:run_reason],
            execution_result: normalize_execution_result(meta[:execution_result])
          }
        end
      end

      def duplicate_examples_report
        snapshot.duplicate_examples.map do |id, entries|
          list = entries.is_a?(::Array) ? entries : []
          {
            id: id,
            count: list.size,
            entries: list.map do |entry|
              entry = {} unless entry.is_a?(::Hash)
              { description: entry[:full_description] || entry[:description], location: location_for(entry) }
            end
          }
        end
      end

      def flaky_examples_report
        snapshot.flaky_examples.to_a.sort.map do |id|
          meta = snapshot.all_examples[id]
          meta = {} unless meta.is_a?(::Hash)
          { id: id, description: meta[:full_description] || meta[:description], location: location_for(meta) }
        end
      end

      def examples_dependency_report
        env_map = snapshot.env_dependency || {}
        snapshot.dependency.keys.sort.map do |id|
          files = snapshot.dependency[id]
          files_array = files.is_a?(::Set) ? files.to_a : Array(files)
          {
            example_id: id,
            files: files_array.sort,
            env_keys: Array(env_map[id]).sort
          }
        end
      end

      def files_dependency_report
        entries = snapshot.reverse_dependency.map do |file_name, example_ids|
          ids_array = example_ids.is_a?(::Set) ? example_ids.to_a : Array(example_ids)
          spec_counts = aggregate_spec_counts(ids_array)
          {
            file_name: file_name,
            example_count: ids_array.size,
            spec_files: spec_counts
          }
        end
        entries.sort_by { |e| [-e[:example_count], e[:file_name].to_s] }
      end

      def aggregate_spec_counts(example_ids)
        counts = Hash.new(0)
        example_ids.each do |id|
          meta = snapshot.all_examples[id]
          next unless meta.is_a?(::Hash)

          spec = meta[:rerun_file_name] || meta[:file_name]
          next if spec.nil? || spec.to_s.empty?

          counts[spec.to_s] += 1
        end
        counts.sort_by { |name, count| [-count, name] }.to_h
      end

      def location_for(meta)
        file = meta[:rerun_file_name] || meta[:file_name]
        line = meta[:rerun_line_number] || meta[:line_number]
        return nil if file.nil?

        trimmed = file.to_s.sub(%r{^/}, '')
        line.nil? ? trimmed : "#{trimmed}:#{line}"
      end

      # Ordering: interrupted > flaky > failed > pending > skipped >
      # execution_result.status. Matches 1.x HTML reporter's status
      # precedence so downstream consumers see the same labels.
      def status_for(id, meta)
        return 'interrupted' if snapshot.interrupted_examples.include?(id)
        return 'flaky' if snapshot.flaky_examples.include?(id)
        return 'failed' if snapshot.failed_examples.include?(id)
        return 'pending' if snapshot.pending_examples.include?(id)
        return 'skipped' if snapshot.skipped_examples.include?(id)

        result = meta[:execution_result]
        result.is_a?(::Hash) ? (result[:status] || 'unknown').to_s : 'unknown'
      end

      def normalize_execution_result(result)
        return nil unless result.is_a?(::Hash)

        {
          started_at: stringify_time(result[:started_at]),
          finished_at: stringify_time(result[:finished_at]),
          run_time: result[:run_time],
          status: (result[:status] || 'unknown').to_s
        }
      end

      def stringify_time(value)
        return nil if value.nil?
        return value if value.is_a?(::String)
        return value.iso8601 if value.respond_to?(:iso8601)

        value.to_s
      end
    end
  end
end
