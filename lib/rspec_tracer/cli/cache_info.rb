# frozen_string_literal: true

require 'json'

module RSpecTracer
  module CLI
    # `rspec-tracer cache:info` — show cache size, last run, and
    # invalidation stats. Reads `last_run.json` + the run-id'd JSON
    # files written by Storage::JsonBackend.
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

        last_run_path = File.join(cache_path, 'last_run.json')
        unless File.file?(last_run_path)
          stdout.puts 'last_run:   no last_run.json yet (run rspec first)'
          return 0
        end

        manifest = JSON.parse(File.read(last_run_path, encoding: 'UTF-8'))
        run_id = manifest['run_id']
        stdout.puts "last_run:   #{run_id}"
        stdout.puts "generated:  #{manifest['generated_at']}" if manifest['generated_at']

        print_run_summary(stdout, cache_path, run_id) if run_id
        0
      rescue StandardError => e
        stderr.puts "cache:info: #{e.class}: #{e.message}"
        1
      end

      def self.print_help(stdout)
        stdout.puts <<~HELP
          Usage: rspec-tracer cache:info

          Show the on-disk cache size, the last run id, and example counts
          for the most recent run. Reads `last_run.json` plus the run-id'd
          JSON files; does not modify any files.
        HELP
        0
      end

      def self.print_run_summary(stdout, cache_path, run_id)
        run_dir = File.join(cache_path, run_id)
        return unless File.directory?(run_dir)

        all_examples_path = File.join(run_dir, 'all_examples.json')
        return unless File.file?(all_examples_path)

        data = JSON.parse(File.read(all_examples_path, encoding: 'UTF-8'))
        total = data.size
        stdout.puts "examples:   #{total} tracked"
      end

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
