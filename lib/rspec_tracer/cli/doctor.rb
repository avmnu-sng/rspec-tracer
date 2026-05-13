# frozen_string_literal: true

module RSpecTracer
  # Internal CLI — see {RSpecTracer} for the user-facing surface.
  # @api private
  module CLI
    # `rspec-tracer doctor` — diagnose config + environment.
    # Reports Ruby + rspec-tracer versions, project root resolution,
    # cache / coverage / report directory state, and SimpleCov / Rails
    # presence. Exits 0 on healthy diagnosis, 1 if any check fails.
    module Doctor
      # @param args [Array<String>] sub-command args (`-h` / `--help`).
      # @param stdout [IO]
      # @param stderr [IO]
      # @return [Integer] exit status (0 = healthy, 1 = any check
      #   FAILed; warnings keep status 0).
      def self.run(args, stdout: $stdout, stderr: $stderr)
        return print_help(stdout) if args.include?('-h') || args.include?('--help')

        require 'rspec_tracer/load_config'

        checks = [
          ruby_version_check,
          tracer_version_check,
          project_root_check,
          cache_path_check,
          coverage_path_check,
          report_path_check,
          git_check,
          simplecov_check,
          rails_check,
          cache_schema_version_check,
          remote_cache_check,
          ar_schema_narrow_attribution_check
        ]
        checks.each { |line| stdout.puts line }
        ok = checks.none? { |line| line.start_with?('FAIL') }
        ok ? 0 : 1
      rescue StandardError => e
        stderr.puts "doctor: #{e.class}: #{e.message}"
        1
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_help(stdout)
        stdout.puts <<~HELP
          Usage: rspec-tracer doctor

          Diagnose rspec-tracer config and environment. Prints a checklist
          of versions, paths, and integrations; exits 0 if all checks pass.
        HELP
        0
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.ruby_version_check
        "OK   ruby:        #{RUBY_DESCRIPTION}"
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.tracer_version_check
        "OK   rspec-tracer: #{RSpecTracer::VERSION}"
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.project_root_check
        "OK   root:        #{RSpecTracer.root}"
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.cache_path_check
        path_check('cache_path:', RSpecTracer.cache_path)
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.coverage_path_check
        path_check('coverage_path:', RSpecTracer.coverage_path)
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.report_path_check
        path_check('report_path:', RSpecTracer.report_path)
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.path_check(label, path)
        return "FAIL #{label} <missing>" if path.nil? || path.empty?
        return "FAIL #{label} #{path} (does not exist)" unless File.directory?(path)
        return "FAIL #{label} #{path} (not writable)" unless File.writable?(path)

        "OK   #{label} #{path}"
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.git_check
        if system('git', 'rev-parse', 'HEAD', out: File::NULL, err: File::NULL)
          'OK   git:         HEAD reachable (remote_cache will work)'
        else
          'WARN git:         not in a git repo (remote_cache will degrade gracefully)'
        end
      end

      # `bundle exec rspec-tracer doctor` runs in its own process via
      # the gem's `bin/rspec-tracer` binstub, NOT inside the user's
      # rspec boot — so app code never loads here and a bare
      # `defined?(::SimpleCov)` check would falsely report "not
      # loaded" on projects that DO have SimpleCov in their
      # Gemfile. Probe `Gem.loaded_specs` first to surface the
      # "installed but not loaded in doctor's process" case
      # separately from "actually not installed."
      def self.simplecov_check
        return 'OK   SimpleCov:   loaded (interop active)' if defined?(::SimpleCov)

        spec = Gem.loaded_specs['simplecov']
        return "INFO SimpleCov:   installed (v#{spec.version}; not loaded in doctor's process)" if spec

        'INFO SimpleCov:   not installed (this is fine; SimpleCov is optional)'
      end

      # See {.simplecov_check} for the doctor-runs-in-its-own-
      # process rationale. Same three-state probe shape: loaded in
      # this process / installed but not loaded / not installed.
      def self.rails_check
        return "OK   Rails:       #{::Rails::VERSION::STRING}" if defined?(::Rails::VERSION) && !::Rails::VERSION.nil?

        spec = Gem.loaded_specs['rails']
        return "INFO Rails:       installed (v#{spec.version}; not loaded in doctor's process)" if spec

        'INFO Rails:       not installed (this is fine for non-Rails projects)'
      end

      # Surface a 1.x->2.0 cache mismatch BEFORE the user runs
      # rspec and watches everything re-run mysteriously. Reads the
      # cached `last_run.json` (if any) and compares its
      # `schema_version` against the gem's `Schema::CURRENT`. Three
      # outcomes: no cache yet (INFO), match (OK), or mismatch (WARN
      # with the cold-run note). Never FAIL - schema mismatches are
      # the documented cold-run path, not a hard error.
      def self.cache_schema_version_check
        require 'rspec_tracer/storage/schema'
        require 'json'

        cache_path = RSpecTracer.cache_path
        last_run_path = File.join(cache_path.to_s, 'last_run.json')
        unless File.file?(last_run_path)
          return 'INFO schema:      no cache yet (next rspec run is cold; expected on first install)'
        end

        manifest = JSON.parse(File.read(last_run_path, encoding: 'UTF-8'))
        stored = manifest['schema_version']
        current = RSpecTracer::Storage::Schema::CURRENT
        if stored == current
          "OK   schema:      v#{current} (matches gem)"
        else
          "WARN schema:      stored v#{stored.inspect} != gem v#{current} " \
            '(next rspec run is a cold run; expected on 1.x->2.0 upgrade)'
        end
      rescue StandardError => e
        "WARN schema:      could not read cache manifest: #{e.class}: #{e.message}"
      end

      # When remote_cache is configured, verify the backend is
      # reachable from doctor's vantage point so the user catches
      # misconfig (typo'd S3 path / unreachable Redis URL / unwritable
      # local-fs dir) BEFORE the next CI run fails. Best-effort: never
      # FAIL the gate, just surface a WARN/INFO line.
      REMOTE_CACHE_PROBES = {
        s3: ->(opts) { remote_cache_s3_check(opts) },
        local_fs: ->(opts) { remote_cache_local_fs_check(opts) },
        redis: ->(opts) { remote_cache_redis_check(opts) }
      }.freeze

      # Internal helper for the tracer pipeline.
      # @api private
      def self.remote_cache_check
        entry = remote_cache_entry
        return 'INFO remote_cache: not configured (skip)' unless entry

        backend, opts = entry
        probe = REMOTE_CACHE_PROBES[backend]
        return "INFO remote_cache: custom backend #{backend.inspect} (skipping reachability probe)" if probe.nil?

        instance_exec(opts, &probe)
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.remote_cache_entry
        return nil unless RSpecTracer.respond_to?(:remote_cache_backend_entry)

        RSpecTracer.remote_cache_backend_entry
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.remote_cache_s3_check(opts)
        bucket = opts[:bucket] || opts['bucket']
        return 'WARN remote_cache: :s3 configured without :bucket' if bucket.nil? || bucket.empty?

        "OK   remote_cache: :s3 bucket=#{bucket} " \
          '(reachability not probed locally; verified end-to-end on next CI run)'
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.remote_cache_local_fs_check(opts)
        path = opts[:path] || opts['path']
        return 'WARN remote_cache: :local_fs configured without :path' if path.nil? || path.empty?
        return "WARN remote_cache: :local_fs path #{path} does not exist" unless File.directory?(path)
        return "WARN remote_cache: :local_fs path #{path} not writable" unless File.writable?(path)

        "OK   remote_cache: :local_fs path=#{path}"
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.remote_cache_redis_check(opts)
        url = opts[:url] || opts['url'] || ENV.fetch('RSPEC_TRACER_REMOTE_CACHE_URI', nil)
        return 'WARN remote_cache: :redis configured without :url' if url.nil? || url.empty?

        "OK   remote_cache: :redis url=#{url} " \
          '(reachability not probed locally; verified end-to-end on next CI run)'
      end

      # Surface the narrow-attribution precondition at diagnostic time.
      # When `track_ar_schema_notifications` is enabled AND Rails is
      # loaded AND the rspec-rails default `use_transactional_fixtures
      # = true` is in effect, per-example BEGIN/COMMIT fires
      # `sql.active_record` inside the rspec-tracer bucket and
      # attribution silently widens. Same shape as the boot-time warn
      # in RSpecTracer.start, surfaced here so users running
      # `rspec-tracer doctor` see the issue without having to boot a
      # full rspec run first.
      def self.ar_schema_narrow_attribution_check
        return 'INFO AR schema:   track_ar_schema_notifications not enabled' unless ar_schema_enabled?
        return 'INFO AR schema:   Rails not loaded' unless rails_loaded?

        if transactional_fixtures_default?
          'WARN AR schema:   track_ar_schema_notifications + use_transactional_fixtures=true ' \
            'silently widens to whole-suite-on-schema-change. See README ' \
            'section "Narrow AR schema attribution".'
        else
          'OK   AR schema:   narrow attribution preconditions look good'
        end
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.ar_schema_enabled?
        return false unless RSpecTracer.respond_to?(:track_ar_schema_notifications?)

        RSpecTracer.track_ar_schema_notifications?
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.rails_loaded?
        defined?(::Rails::VERSION) && !::Rails::VERSION.nil?
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.transactional_fixtures_default?
        return false unless defined?(::RSpec) && ::RSpec.respond_to?(:configuration)

        cfg = ::RSpec.configuration
        return false unless cfg.respond_to?(:use_transactional_fixtures)

        cfg.use_transactional_fixtures != false
      rescue StandardError
        false
      end
    end
  end
end
