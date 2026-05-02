# frozen_string_literal: true

require 'optparse'

# Require the top-level entry to pull in `docile` (used by
# `Configuration#configure`) plus the autoloads sub-commands rely on.
# Loading `rspec_tracer` does NOT call `RSpecTracer.start` - the engine
# stays inert until a user invokes it explicitly.
require 'rspec_tracer'

module RSpecTracer
  # Command-line entry for the `rspec-tracer` binary. Five sub-commands
  # per USER_FACING_SURFACE.md §10: `doctor`, `cache:info`, `cache:clear`,
  # `report:open`, `explain <example>`.
  #
  # The CLI is opt-in — the canonical CI flow continues to go through
  # `rake rspec_tracer:remote_cache:*` tasks per USER_FACING_SURFACE.md
  # §5. Sub-commands operate against the local cache + report
  # directories resolved from the project's `.rspec-tracer` config
  # (loaded lazily on first sub-command dispatch, not at CLI load time —
  # `doctor` deliberately runs without requiring a configured project).
  module CLI
    SUB_COMMANDS = {
      'doctor' => 'Doctor',
      'cache:info' => 'CacheInfo',
      'cache:clear' => 'CacheClear',
      'report:open' => 'ReportOpen',
      'explain' => 'Explain'
    }.freeze

    def self.run(argv, stdout: $stdout, stderr: $stderr)
      args = argv.dup
      return print_top_level_help(stdout) if args.empty? || %w[-h --help help].include?(args.first)
      return print_version(stdout) if %w[-v --version].include?(args.first)

      dispatch(args, stdout: stdout, stderr: stderr)
    rescue StandardError => e
      stderr.puts "rspec-tracer: #{e.class}: #{e.message}"
      1
    end

    def self.dispatch(args, stdout:, stderr:)
      sub = args.shift
      klass_name = SUB_COMMANDS[sub]
      return unknown_sub_command(sub, stderr) if klass_name.nil?

      load_sub_command(klass_name)
      RSpecTracer::CLI.const_get(klass_name).run(args, stdout: stdout, stderr: stderr)
    end

    def self.unknown_sub_command(sub, stderr)
      stderr.puts "rspec-tracer: unknown sub-command #{sub.inspect}"
      stderr.puts "  available: #{SUB_COMMANDS.keys.join(', ')}"
      1
    end

    def self.print_top_level_help(stdout)
      stdout.puts <<~HELP
        Usage: rspec-tracer <sub-command> [options]

        Sub-commands:
          doctor          Diagnose rspec-tracer config + environment.
          cache:info      Show cache size, last run timestamp, and example counts.
          cache:clear     Remove cache, coverage, and report directories.
          report:open     Open the HTML report in the default browser.
          explain <id>    Show why an example is scheduled to run or skip.

        Options:
          -h, --help      Print this help message.
          -v, --version   Print rspec-tracer version.

        Run `rspec-tracer <sub-command> --help` for sub-command options.
      HELP
      0
    end

    def self.print_version(stdout)
      stdout.puts "rspec-tracer #{RSpecTracer::VERSION}"
      0
    end

    def self.load_sub_command(klass_name)
      filename = klass_name.gsub(/([A-Z])/) { |m| "_#{m.downcase}" }.sub(/^_/, '')
      require_relative "cli/#{filename}"
    rescue LoadError => e
      # LoadError isn't a StandardError, so the outer `rescue StandardError`
      # in `.run` wouldn't catch it. Re-raise as StandardError so the dispatch
      # path stays uniform: any sub-command resolution failure prints
      # `rspec-tracer: <class>: <message>` and exits 1.
      raise StandardError, "could not load sub-command #{klass_name.inspect}: #{e.message}"
    end
  end
end
