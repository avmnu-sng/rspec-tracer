# frozen_string_literal: true

require 'rspec_tracer/storage/backend'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/schema'
require 'rspec_tracer/storage/sqlite_backend' if RUBY_ENGINE == 'ruby'

module RSpecTracer
  # Internal CLI — see {RSpecTracer} for the user-facing surface.
  # @api private
  module CLI
    # `rspec-tracer explain <example>` — show why a given example is
    # scheduled to run or skip on the next rspec invocation. Backend-
    # agnostic: dispatches through {RSpecTracer::Storage::Backend.build}
    # so `storage_backend :sqlite` resolves the latest run from the
    # meta table instead of the JsonBackend-only `last_run.json` file.
    module Explain
      # @param args [Array<String>] sub-command args. First positional
      #   arg is the example_id (or substring) to explain.
      # @param stdout [IO]
      # @param stderr [IO]
      # @return [Integer] exit status (0 = explanation printed,
      #   1 = example not found / cache missing).
      def self.run(args, stdout: $stdout, stderr: $stderr)
        return print_help(stdout) if args.empty? || args.include?('-h') || args.include?('--help')

        require 'rspec_tracer/load_config'
        cache_path = RSpecTracer.cache_path

        snapshot = load_snapshot(cache_path, stderr)
        return 1 if snapshot.nil?

        match = find_example(snapshot.all_examples, args.first)
        return no_match(args.first, snapshot.all_examples, stderr) if match.nil?

        print_explanation(stdout, match, snapshot)
        0
      rescue StandardError => e
        stderr.puts "explain: #{e.class}: #{e.message}"
        1
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.load_snapshot(cache_path, stderr)
        backend = Storage::Backend.build(cache_path: cache_path, configuration: RSpecTracer)
        run_id = backend.last_run_id
        if run_id.nil? || run_id.to_s.empty?
          stderr.puts "explain: no cache yet at #{cache_path} — run rspec first"
          return nil
        end

        snapshot = backend.load_graph(schema_version: Storage::Schema::CURRENT)
        if snapshot.nil?
          stderr.puts "explain: cache at #{cache_path} is incompatible with this rspec-tracer; next rspec run is cold"
          return nil
        end

        snapshot
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.no_match(query, all_examples, stderr)
        stderr.puts "explain: no example matching #{query.inspect}"
        stderr.puts "  cache has #{all_examples.size} examples; pass an example_id or substring of description"
        1
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_help(stdout)
        stdout.puts <<~HELP
          Usage: rspec-tracer explain <example_id_or_substring>

          Show why an example is scheduled to run or skip. Matches against
          example_id exactly first, then falls back to a substring match
          on the example's full_description. Backend-aware: works under
          `storage_backend :json` (default) and `storage_backend :sqlite`.
          Requires a prior rspec run.
        HELP
        0
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.find_example(all_examples, query)
        return all_examples[query] if all_examples.key?(query)

        all_examples.find do |id, meta|
          meta = {} unless meta.is_a?(::Hash)
          desc = fetch_meta(meta, 'full_description') || fetch_meta(meta, 'description') || ''
          id.include?(query) || desc.include?(query)
        end&.last
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_explanation(stdout, meta, snapshot)
        meta = {} unless meta.is_a?(::Hash)
        format_lines(meta).each { |line| stdout.puts line }
        print_dependency_summary(stdout, meta, snapshot)
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.format_lines(meta)
        id = fetch_meta(meta, 'example_id', 'id') || '<unknown>'
        file = fetch_meta(meta, 'rerun_file_name', 'file_name')
        line = fetch_meta(meta, 'rerun_line_number', 'line_number')
        status = dig_meta(meta, 'execution_result', 'status') || fetch_meta(meta, 'status') || 'unknown'
        [
          "id:           #{id}",
          "description:  #{fetch_meta(meta, 'full_description', 'description')}",
          "location:     #{file}:#{line}",
          "last status:  #{status}",
          "run reason:   #{fetch_meta(meta, 'run_reason') || '<not recorded>'}"
        ]
      end

      # Look up a key from a Hash, tolerating both String and Symbol
      # storage. Snapshot Hashes round-tripped through JSON yield
      # String keys; the post-#182 msgpack serializer preserves
      # Symbol keys end-to-end, so callers can't assume either shape.
      def self.fetch_meta(meta, *keys)
        keys.each do |k|
          v = meta[k]
          return v unless v.nil?

          sym_value = meta[k.to_sym]
          return sym_value unless sym_value.nil?
        end
        nil
      end

      # Look up a nested key from a Hash, tolerating both String and
      # Symbol storage at each level. See {.fetch_meta} for rationale.
      def self.dig_meta(meta, *keys)
        keys.reduce(meta) do |acc, k|
          break nil if acc.nil? || !acc.is_a?(::Hash)

          acc[k] || acc[k.to_sym]
        end
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_dependency_summary(stdout, meta, snapshot)
        id = fetch_meta(meta, 'example_id', 'id')
        deps = snapshot.dependency || {}
        files = Array(deps[id])
        stdout.puts "dependencies: #{files.size} files tracked"
        files.first(10).each { |f| stdout.puts "  - #{f}" }
        stdout.puts "  ... (#{files.size - 10} more)" if files.size > 10
      end
    end
  end
end
