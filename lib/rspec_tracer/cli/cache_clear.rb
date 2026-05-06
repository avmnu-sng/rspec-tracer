# frozen_string_literal: true

require 'fileutils'

module RSpecTracer
  # Internal CLI — see {RSpecTracer} for the user-facing surface.
  # @api private
  module CLI
    # `rspec-tracer cache:clear` — remove cache, coverage, and report
    # directories. Prompts for confirmation unless `--yes` is passed.
    # The next rspec run is a cold run.
    module CacheClear
      # @param args [Array<String>] sub-command args (`-y` / `--yes`
      #   skips confirmation; `-h` / `--help` prints help).
      # @param stdout [IO]
      # @param stderr [IO]
      # @return [Integer] exit status (0 = success / aborted, 1 = error).
      def self.run(args, stdout: $stdout, stderr: $stderr)
        return print_help(stdout) if args.include?('-h') || args.include?('--help')

        require 'rspec_tracer/load_config'
        existing = existing_targets
        return nothing_to_remove(stdout) if existing.empty?

        announce(stdout, existing)
        force = args.include?('--yes') || args.include?('-y')
        return aborted(stdout) unless force || confirm?(stdout)

        remove_each(stdout, existing)
        0
      rescue StandardError => e
        stderr.puts "cache:clear: #{e.class}: #{e.message}"
        1
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.existing_targets
        [RSpecTracer.cache_path, RSpecTracer.coverage_path, RSpecTracer.report_path]
          .select { |path| File.directory?(path) }
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.nothing_to_remove(stdout)
        stdout.puts 'cache:clear: nothing to remove (cache directories do not exist)'
        0
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.announce(stdout, existing)
        stdout.puts 'cache:clear: will remove:'
        existing.each { |path| stdout.puts "  - #{path}" }
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.confirm?(stdout)
        stdout.print 'Proceed? [y/N] '
        stdout.flush
        response = $stdin.gets&.chomp&.downcase
        %w[y yes].include?(response)
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.aborted(stdout)
        stdout.puts 'cache:clear: aborted'
        0
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.remove_each(stdout, existing)
        existing.each do |path|
          FileUtils.rm_rf(path)
          stdout.puts "  removed #{path}"
        end
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_help(stdout)
        stdout.puts <<~HELP
          Usage: rspec-tracer cache:clear [--yes]

          Remove cache, coverage, and report directories. The next rspec
          run will be a cold run (full re-execution + cache rebuild).

          Options:
            -y, --yes   Skip the confirmation prompt.
        HELP
        0
      end
    end
  end
end
