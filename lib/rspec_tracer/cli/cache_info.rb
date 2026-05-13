# frozen_string_literal: true

require 'rspec_tracer/storage/backend'
require 'rspec_tracer/storage/schema'

module RSpecTracer
  # Internal CLI — see {RSpecTracer} for the user-facing surface.
  # @api private
  module CLI
    # `rspec-tracer cache:info` — show cache size, last run, and
    # invalidation stats. Backend-agnostic: dispatches through
    # {RSpecTracer::Storage::Backend.build} so `storage_backend
    # :sqlite` reports the populated cache instead of the false
    # "no cache yet" the JsonBackend-only path used to emit.
    module CacheInfo
      # @param args [Array<String>] sub-command args (`-h` / `--help`).
      # @param stdout [IO]
      # @param stderr [IO]
      # @return [Integer] exit status (0 = success).
      def self.run(args, stdout: $stdout, stderr: $stderr)
        return print_help(stdout) if args.include?('-h') || args.include?('--help')

        require 'rspec_tracer/load_config'

        cache_path = RSpecTracer.cache_path
        stdout.puts "cache_path: #{cache_path}"
        stdout.puts "size:       #{format_bytes(directory_size(cache_path))}"

        backend = Storage::Backend.build(cache_path: cache_path, configuration: RSpecTracer)
        run_id = backend.last_run_id
        if run_id.nil? || run_id.to_s.empty?
          stdout.puts 'last_run:   no cache yet (run rspec first)'
          return 0
        end

        stdout.puts "last_run:   #{run_id}"
        print_example_count(stdout, backend)
        0
      rescue StandardError => e
        stderr.puts "cache:info: #{e.class}: #{e.message}"
        1
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_help(stdout)
        stdout.puts <<~HELP
          Usage: rspec-tracer cache:info

          Show the on-disk cache size, the last run id, and example counts
          for the most recent run. Backend-aware: works under
          `storage_backend :json` (default) and `storage_backend :sqlite`.
          Read-only; does not modify the cache.
        HELP
        0
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_example_count(stdout, backend)
        snapshot = backend.load_graph(schema_version: Storage::Schema::CURRENT)
        if snapshot.nil?
          stdout.puts 'examples:   <unknown> (schema mismatch; next rspec run will be cold)'
          return
        end

        stdout.puts "examples:   #{snapshot.all_examples.size} tracked"
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.directory_size(path)
        return 0 unless File.directory?(path)

        total = 0
        Dir.glob(File.join(path, '**', '*'), File::FNM_DOTMATCH).each do |entry|
          next unless File.file?(entry)

          total += File.size(entry)
        rescue SystemCallError
          next
        end
        total
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.format_bytes(bytes)
        return '0 B' if bytes <= 0

        units = %w[B KB MB GB]
        scale = bytes
        unit_index = 0
        while scale >= 1024 && unit_index < units.length - 1
          scale /= 1024.0
          unit_index += 1
        end
        format('%<scale>.1f %<unit>s', scale: scale, unit: units[unit_index])
      end
    end
  end
end
