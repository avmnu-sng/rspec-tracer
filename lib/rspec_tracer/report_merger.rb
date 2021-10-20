# frozen_string_literal: true

module RSpecTracer
  class ReportMerger
    attr_reader :all_examples, :duplicate_examples, :interrupted_examples,
                :flaky_examples, :failed_examples, :pending_examples, :skipped_examples,
                :all_files, :dependency, :reverse_dependency, :examples_coverage, :last_run

    def initialize
      @last_run = {}
      @all_examples = {}
      @duplicate_examples = {}
      @interrupted_examples = Set.new
      @flaky_examples = Set.new
      @failed_examples = Set.new
      @pending_examples = Set.new
      @skipped_examples = Set.new
      @all_files = {}
      @dependency = Hash.new { |hash, key| hash[key] = Set.new }
      @reverse_dependency = {}
      @examples_coverage = {}
    end

    def merge(reports_dir)
      reports_dir.each do |report_dir|
        next unless File.directory?(report_dir)

        merge_cache(load_cache(report_dir))
        merge_last_run_report(File.dirname(report_dir))
      end

      @dependency.transform_values!(&:to_a)

      @reverse_dependency = RSpecTracer::ReportGenerator.new(self, nil).reverse_dependency_report
    end

    private

    def load_cache(cache_dir)
      cache = RSpecTracer::Cache.new

      cache.send(:load_all_examples_cache, cache_dir, discard_run_reason: false)
      cache.send(:load_duplicate_examples_cache, cache_dir)
      cache.send(:load_interrupted_examples_cache, cache_dir)
      cache.send(:load_flaky_examples_cache, cache_dir)
      cache.send(:load_failed_examples_cache, cache_dir)
      cache.send(:load_pending_examples_cache, cache_dir)
      cache.send(:load_skipped_examples_cache, cache_dir)
      cache.send(:load_all_files_cache, cache_dir)
      cache.send(:load_dependency_cache, cache_dir)
      cache.send(:load_examples_coverage_cache, cache_dir)

      cache
    end

    def merge_cache(cache)
      @all_examples.merge!(cache.all_examples) { |_, v1, v2| v1[:run_reason] ? v1 : v2 }
      @duplicate_examples.merge!(cache.duplicate_examples) { |_, v1, v2| v1 + v2 }
      @interrupted_examples.merge(cache.interrupted_examples)
      @flaky_examples.merge(cache.flaky_examples)
      @failed_examples.merge(cache.failed_examples)
      @pending_examples.merge(cache.pending_examples)
      @skipped_examples.merge(cache.skipped_examples)
      @all_files.merge!(cache.all_files)
      @dependency.merge!(cache.dependency) { |_, v1, v2| v1.merge(v2) }
      @examples_coverage.merge!(cache.examples_coverage) do |_, v1, v2|
        v1.merge(v2) { |_, v3, v4| v3.merge(v4) { |_, v5, v6| v5 + v6 } }
      end
    end

    def merge_last_run_report(cache_dir)
      file_name = File.join(cache_dir, 'last_run.json')
      cached_last_run = JSON.parse(File.read(file_name), symbolize_names: true)
      cached_last_run[:pid] = [cached_last_run[:pid]]

      cached_last_run.delete_if { |key, _| %i[run_id timestamp].include?(key) }

      @last_run.merge!(cached_last_run) { |_, v1, v2| v1 + v2 }
    end
  end
end
