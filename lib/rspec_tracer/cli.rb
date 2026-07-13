# frozen_string_literal: true

require 'optparse'

# Only the Logger class, NOT the full library, whose boot would
# `load` the project config. {CLI.with_default_logger_out} needs the
# class defined before that boot so the config-load window cannot
# construct a stdout-bound logger.
require_relative 'logger'

module RSpecTracer
  # Command-line entry for the `rspec-tracer` binary. Six sub-commands
  # per USER_FACING_SURFACE.md section 10: `doctor`, `cache:info`,
  # `cache:clear`, `report:open`, `explain <example>`,
  # `blast-radius <file>`.
  #
  # The CLI is opt-in — the canonical CI flow continues to go through
  # `rake rspec_tracer:remote_cache:*` tasks per USER_FACING_SURFACE.md
  # §5. Sub-commands operate against the local cache + report
  # directories resolved from the project's `.rspec-tracer` config.
  # {.run} loads the tracer library (and with it the project + global
  # `.rspec-tracer` configs) via {.load_tracer} right before
  # sub-command dispatch, so `--help` / `--version` work even in a
  # project whose config is broken, and a config file that raises at
  # load time degrades to a one-line message + exit 1 instead of a
  # raw backtrace.
  #
  # @api private
  module CLI
    # Internal constant.
    # @api private
    SUB_COMMANDS = {
      'doctor' => 'Doctor',
      'cache:info' => 'CacheInfo',
      'cache:clear' => 'CacheClear',
      'report:open' => 'ReportOpen',
      'explain' => 'Explain',
      'blast-radius' => 'BlastRadius'
    }.freeze

    # CLI entry. Called by `bin/rspec-tracer` with `ARGV`. Wraps every
    # sub-command in a top-level rescue so the binary always exits
    # with a meaningful integer status (0 / 1) instead of a backtrace.
    #
    # @param argv [Array<String>] command-line arguments (excluding
    #   the program name)
    # @param stdout [IO] stream for normal output (default `$stdout`)
    # @param stderr [IO] stream for errors / diagnostics (default `$stderr`)
    # @return [Integer] exit status (0 = success, 1 = failure)
    def self.run(argv, stdout: $stdout, stderr: $stderr)
      args = argv.dup
      return print_top_level_help(stdout) if args.empty? || %w[-h --help help].include?(args.first)
      return print_version(stdout) if %w[-v --version].include?(args.first)

      with_default_logger_out(stderr) do
        if load_tracer(stderr)
          with_logger_on(stderr) { dispatch(args, stdout: stdout, stderr: stderr) }
        else
          1
        end
      end
    rescue Errno::EPIPE
      # A downstream pipe consumer (`rspec-tracer ... | head`) closed
      # early, which is routine in shell pipelines, not a failure. Exit 0
      # without printing: writing to stderr could raise EPIPE again
      # when both streams share the closed pipe.
      0
    rescue StandardError => e
      stderr.puts "rspec-tracer: #{e.class}: #{e.message}"
      1
    end

    # Boot the tracer library for sub-command dispatch. Loading
    # `rspec_tracer` pulls in `docile` (used by
    # `Configuration#configure`), the modules sub-commands rely on,
    # AND the project's `.rspec-tracer` / `~/.rspec-tracer` configs
    # (arbitrary user Ruby, `load`ed by `load_config`). It does NOT
    # call `RSpecTracer.start` - the engine stays inert until a user
    # invokes it explicitly.
    #
    # A raising config must not crash the binary with a backtrace:
    # rescue ScriptError as well as StandardError because a syntax
    # error in `.rspec-tracer` raises SyntaxError, which is not a
    # StandardError and would sail past {.run}'s rescue.
    #
    # @param stderr [IO]
    # @return [Boolean] true when the tracer library (and the user
    #   configs it loads) booted cleanly
    def self.load_tracer(stderr)
      require 'rspec_tracer'
      true
    rescue ScriptError, StandardError => e
      stderr.puts "rspec-tracer: could not load configuration (.rspec-tracer): #{e.class}: #{e.message}"
      false
    end

    # Point {RSpecTracer::Logger.default_out} at the CLI's stderr for
    # the duration of library boot + sub-command dispatch, restoring
    # the previous value afterwards. This must wrap {.load_tracer}:
    # booting the library `load`s the project + global `.rspec-tracer`
    # configs, and those can write through the logger BEFORE
    # {.with_logger_on} ever runs: the 1.x-compat deprecation shims
    # (`reports_s3_path`, `use_local_aws`) fire a one-time
    # `logger.warn` at first use, and in a fresh CLI process
    # "one-time" means every invocation. The logger's default
    # destination is stdout (the stream machine consumers parse),
    # so that warning would land ahead of e.g. the `blast-radius
    # --json` document and break `| jq`. With the default rebound,
    # every logger constructed during the window binds to stderr,
    # including loggers recreated mid-load when a config sets
    # `log_level` (which resets the memoized instance) after a
    # deprecated DSL call. Normal `rspec` runs (whose users expect
    # stdout logs) never enter this path and stay untouched.
    # @api private
    def self.with_default_logger_out(stderr)
      previous = RSpecTracer::Logger.default_out
      RSpecTracer::Logger.default_out = stderr
      yield
    ensure
      RSpecTracer::Logger.default_out = previous
    end

    # Bind the tracer's internal logger to the CLI's stderr for the
    # duration of sub-command dispatch, restoring the previous logger
    # afterwards. Backend diagnostics run through `RSpecTracer.logger`
    # (e.g. {RSpecTracer::Storage::Backend.build}'s sqlite-unavailable
    # fallback warning, JsonBackend's schema-mismatch info line).
    # {.with_default_logger_out} already redirects loggers constructed
    # during the CLI window; this layer additionally rebinds a logger
    # that was memoized into `RSpecTracer.@logger` BEFORE {.run} was
    # called (possible for in-process callers, the spec suite or a
    # user embedding the CLI, where the library booted earlier with
    # the stdout default). Sub-commands like `blast-radius --json`
    # promise exactly one JSON document on stdout, so a diagnostic
    # line printed ahead of it breaks `| jq`; together the two layers
    # keep ALL diagnostics on stderr alongside the CLI's own messages.
    #
    # `RSpecTracer.logger` memoizes into `@logger`
    # (Configuration#logger); the ivar is seeded directly because
    # Configuration deliberately exposes no logger setter; adding
    # one would leak it into the user-facing `configure` DSL surface.
    # @api private
    def self.with_logger_on(stderr)
      previous = RSpecTracer.instance_variable_get(:@logger)
      RSpecTracer.instance_variable_set(
        :@logger, RSpecTracer::Logger.new(RSpecTracer.log_level, out: stderr)
      )
      yield
    ensure
      RSpecTracer.instance_variable_set(:@logger, previous)
    end

    # Internal helper for the tracer pipeline.
    # @api private
    def self.dispatch(args, stdout:, stderr:)
      sub = args.shift
      klass_name = SUB_COMMANDS[sub]
      return unknown_sub_command(sub, stderr) if klass_name.nil?

      load_sub_command(klass_name)
      RSpecTracer::CLI.const_get(klass_name).run(args, stdout: stdout, stderr: stderr)
    end

    # Internal helper for the tracer pipeline.
    # @api private
    def self.unknown_sub_command(sub, stderr)
      stderr.puts "rspec-tracer: unknown sub-command #{sub.inspect}"
      stderr.puts "  available: #{SUB_COMMANDS.keys.join(', ')}"
      1
    end

    # Internal helper for the tracer pipeline.
    # @api private
    def self.print_top_level_help(stdout)
      stdout.puts <<~HELP
        Usage: rspec-tracer <sub-command> [options]

        Sub-commands:
          doctor          Diagnose rspec-tracer config + environment.
          cache:info      Show cache size, last run timestamp, and example counts.
          cache:clear     Remove cache, coverage, and report directories.
          report:open     Open the HTML report in the default browser.
          explain <id>    Show why an example is scheduled to run or skip.
          blast-radius <f>  Show which examples a file change would re-run.

        Options:
          -h, --help      Print this help message.
          -v, --version   Print rspec-tracer version.

        Run `rspec-tracer <sub-command> --help` for sub-command options.
      HELP
      0
    end

    # Internal helper for the tracer pipeline.
    # @api private
    def self.print_version(stdout)
      # Only the version constant - not the full library, whose boot
      # would `load` the project config and could raise before the
      # version ever printed.
      require 'rspec_tracer/version'
      stdout.puts "rspec-tracer #{RSpecTracer::VERSION}"
      0
    end

    # Internal helper for the tracer pipeline.
    # @api private
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
