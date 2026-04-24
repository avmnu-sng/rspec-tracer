# frozen_string_literal: true

require 'uri'

require_relative 'filter'
require_relative 'logger'

module RSpecTracer
  # rubocop:disable Metrics/ModuleLength
  module Configuration
    class InvalidUsageError < StandardError; end

    ALLOWED_CONFIGURER = %w[
      lib/rspec_tracer/load_default_config.rb
      lib/rspec_tracer/load_global_config.rb
      lib/rspec_tracer/load_local_config.rb
    ].freeze

    DEFAULT_CACHE_DIR = 'rspec_tracer_cache'
    DEFAULT_COVERAGE_DIR = 'rspec_tracer_coverage'
    DEFAULT_REPORT_DIR = 'rspec_tracer_report'
    DEFAULT_LOCK_FILE = 'rspec_tracer.lock'
    DEFAULT_STORAGE_BACKEND = :json
    # :sqlite opt-in: MRI >= 3.2 only (sqlite3 2.x gem requirement).
    # Kept closed so typos raise early.
    STORAGE_BACKEND_NAMES = %i[json sqlite].freeze
    # Keys allowed in `storage_backend`'s opts hash. `:serializer` is
    # accepted only for the :json backend (see validate_storage_opts!).
    STORAGE_BACKEND_OPT_KEYS = %i[serializer].freeze
    STORAGE_BACKEND_SERIALIZERS = %i[json msgpack].freeze
    # Per-save retention on the local cache's run-id directories.
    # 5 keeps enough history for rollback debugging without letting
    # the cache grow unbounded (issue #20). 0 opts out entirely.
    DEFAULT_CACHE_RETENTION_LOCAL_COUNT = 5
    # Size budgets (MiB). Warn at save time when any single cache
    # file exceeds the per-file threshold or when the cache total
    # exceeds the aggregate threshold. Surfaces B11 symptoms
    # (dependency.json ballooning past the few-MB range) while
    # the user can still act on them. Set to 0 to disable either
    # individually.
    DEFAULT_CACHE_SIZE_WARN_PER_FILE_MB = 50
    DEFAULT_CACHE_SIZE_WARN_TOTAL_MB = 500

    LOG_LEVEL = {
      off: 0,
      debug: 1,
      info: 2,
      warn: 3,
      error: 4
    }.freeze

    def configure(&)
      configurers = caller_locations(1, 2).map(&:path)
      invalid = configurers.none? do |configurer|
        ALLOWED_CONFIGURER.any? do |allowed_configurer|
          configurer.end_with?(allowed_configurer)
        end
      end

      raise InvalidUsageError, 'You must define configurations in a .rspec-tracer file' if invalid

      RSpecTracer::Configuration.module_exec do
        RSpecTracer::Configuration.private_instance_methods(false).each do |method_name|
          alias_method :"_#{method_name}", method_name

          # Forward `**kwargs` too so DSL methods can accept Ruby 3+
          # keyword args (e.g. `track_rails_defaults except: [:views]`,
          # M3.8's `storage_backend :json, serializer: :msgpack`).
          # Before M4.1 this wrapper forwarded `*args, &block` only and
          # silently stripped kwargs; see M3.4 handoff notes.
          define_method method_name do |*args, **kwargs, &block|
            send(:"_#{method_name}", *args, **kwargs, &block)
          end
        end
      end

      Docile.dsl_eval(self, &)
    end

    private

    def root(root = nil)
      return @root if defined?(@root) && root.nil?

      @cache_path = nil
      @report_path = nil
      @coverage_path = nil

      @root = File.expand_path(root || Dir.getwd)
    end

    def project_name(new_name = nil)
      return @project_name if defined?(@project_name) && @project_name && new_name.nil?

      @project_name = new_name if new_name.is_a?(String)
      @project_name ||= File.basename(root.split('/').last).capitalize.tr('_', ' ')
    end

    def cache_dir(dir = nil)
      return @cache_dir if defined?(@cache_dir) && dir.nil?

      @cache_path = nil
      @cache_dir = if ENV.key?('RSPEC_TRACER_CACHE_DIR')
                     ENV['RSPEC_TRACER_CACHE_DIR']
                   else
                     dir || DEFAULT_CACHE_DIR
                   end
    end

    def cache_path
      @cache_path ||= begin
        cache_path = File.expand_path(cache_dir, root)
        cache_path = File.join(cache_path, ENV['TEST_SUITE_ID'].to_s) if ENV['TEST_SUITE_ID']
        cache_path = File.join(cache_path, parallel_tests_id) if RSpecTracer.parallel_tests?

        FileUtils.mkdir_p(cache_path)

        cache_path
      end
    end

    def report_dir(dir = nil)
      return @report_dir if defined?(@report_dir) && dir.nil?

      @report_path = nil
      @report_dir = if ENV.key?('RSPEC_TRACER_REPORT_DIR')
                      ENV['RSPEC_TRACER_REPORT_DIR']
                    else
                      dir || DEFAULT_REPORT_DIR
                    end
    end

    def report_path
      @report_path ||= begin
        report_path = File.expand_path(report_dir, root)
        report_path = File.join(report_path, ENV['TEST_SUITE_ID'].to_s) if ENV['TEST_SUITE_ID']
        report_path = File.join(report_path, parallel_tests_id) if RSpecTracer.parallel_tests?

        FileUtils.mkdir_p(report_path)

        report_path
      end
    end

    def coverage_dir(dir = nil)
      return @coverage_dir if defined?(@coverage_dir) && dir.nil?

      @coverage_path = nil
      @coverage_dir = if ENV.key?('RSPEC_TRACER_COVERAGE_DIR')
                        ENV['RSPEC_TRACER_COVERAGE_DIR']
                      else
                        dir || DEFAULT_COVERAGE_DIR
                      end
    end

    def coverage_path
      @coverage_path ||= begin
        coverage_path = File.expand_path(coverage_dir, root)
        coverage_path = File.join(coverage_path, ENV['TEST_SUITE_ID'].to_s) if ENV['TEST_SUITE_ID']
        coverage_path = File.join(coverage_path, parallel_tests_id) if RSpecTracer.parallel_tests?

        FileUtils.mkdir_p(coverage_path)

        coverage_path
      end
    end

    # M7.1 canonical DSL for the remote cache backend. Single-entry
    # accumulator; raises on a second call so a misconfigured
    # `.rspec-tracer` fails fast instead of silently picking one.
    #
    # Shapes:
    #   remote_cache_backend :s3, bucket: 'my-bucket', prefix: 'rspec-tracer'
    #   remote_cache_backend :s3, bucket: 'x', prefix: 'y', local: true
    #   remote_cache_backend MyBackend, some_opt: 'value'
    #
    # Symbol names are not validated at config time because M7.2
    # backends (`:local_fs`, `:redis`) resolve at UserTasks build time;
    # a typo there surfaces as an "unknown remote_cache_backend: :s3x"
    # error in the Rake task, which is the right layer for the message.
    def remote_cache_backend(name_or_class, **opts)
      if defined?(@remote_cache_backend_entry) && @remote_cache_backend_entry
        raise InvalidUsageError, 'remote_cache_backend already configured'
      end

      validate_remote_cache_backend(name_or_class)
      @remote_cache_backend_entry = [name_or_class, opts.dup.freeze].freeze
    end

    # Reader: returns the [name_or_class, opts] pair or nil. Called
    # from `RemoteCache::UserTasks` at task dispatch time.
    def remote_cache_backend_entry
      return nil unless defined?(@remote_cache_backend_entry)

      @remote_cache_backend_entry
    end

    def validate_remote_cache_backend(name_or_class)
      case name_or_class
      when ::Symbol, ::Class
        nil
      else
        raise InvalidUsageError,
              "remote_cache_backend: expected Symbol or Class, got #{name_or_class.class}"
      end
    end

    # Convenience DSL: `remote_cache_uri '<scheme>://...'` parses the
    # URI and calls `remote_cache_backend` with the right backend +
    # connection params. Also accepts ENV `RSPEC_TRACER_REMOTE_CACHE_URI`.
    # Supported schemes:
    #   s3://<bucket>/<prefix>             -> S3Backend
    #   file:///absolute/path              -> LocalFsBackend (root:)
    #   redis://[user:pass@]host:port/<db> -> RedisBackend (prefix: 'rspec-tracer')
    # Users who need finer control (custom Redis prefix, LocalFs on a
    # relative path) use `remote_cache_backend` directly.
    def remote_cache_uri(uri = nil)
      return @remote_cache_uri if defined?(@remote_cache_uri) && uri.nil?

      value = ENV.fetch('RSPEC_TRACER_REMOTE_CACHE_URI', uri)
      return nil if value.nil?

      parsed = parse_remote_cache_uri(value)
      dispatch_remote_cache_uri(parsed)

      @remote_cache_uri = value
    end

    def dispatch_remote_cache_uri(parsed)
      case parsed.scheme
      when 's3'
        prefix = parsed.path.to_s.sub(%r{^/}, '')
        remote_cache_backend(:s3, bucket: parsed.host, prefix: prefix)
      when 'file'
        remote_cache_backend(:local_fs, root: parsed.path.to_s)
      when 'redis', 'rediss'
        remote_cache_backend(:redis, url: parsed.to_s, prefix: 'rspec-tracer')
      else
        raise InvalidUsageError,
              "unsupported remote_cache_uri scheme: #{parsed.scheme.inspect} " \
              "(supported: 's3', 'file', 'redis', 'rediss')"
      end
    end

    # Validate a parsed URI per the active scheme. Host presence is the
    # common structural signal for S3 / Redis; `file://` uses path
    # instead (host is optional and usually empty).
    def parse_remote_cache_uri(value)
      parsed = URI.parse(value)
      raise InvalidUsageError, "invalid remote_cache_uri: #{value.inspect}" unless valid_remote_cache_uri?(parsed)

      parsed
    rescue URI::InvalidURIError => e
      raise InvalidUsageError, "invalid remote_cache_uri: #{value.inspect} (#{e.message})"
    end

    def valid_remote_cache_uri?(parsed)
      return false if parsed.scheme.nil?

      case parsed.scheme
      when 'file'
        !parsed.path.to_s.empty?
      else
        !parsed.host.nil? && !parsed.host.empty?
      end
    end

    # Retention knobs (closes issue #20). Mutually exclusive: count
    # and duration bound the main tier from different axes. PR tier
    # uses `cache_retention_pr_branch_ttl` independently.
    def cache_retention_count(count = nil)
      return @cache_retention_count if defined?(@cache_retention_count) && count.nil?
      return nil if count.nil?

      raise_if_retention_conflict(:cache_retention_duration)
      unless count.is_a?(::Integer) && count.positive?
        raise InvalidUsageError, "cache_retention_count must be a positive integer, got #{count.inspect}"
      end

      @cache_retention_count = count
    end

    def cache_retention_duration(spec = nil)
      return @cache_retention_duration_raw if defined?(@cache_retention_duration_raw) && spec.nil?
      return nil if spec.nil?

      raise_if_retention_conflict(:cache_retention_count)
      seconds = parse_retention_duration_seconds(spec)
      @cache_retention_duration_raw = spec
      @cache_retention_duration_seconds = seconds
    end

    def cache_retention_duration_seconds
      return nil unless defined?(@cache_retention_duration_seconds)

      @cache_retention_duration_seconds
    end

    def cache_retention_pr_branch_ttl(spec = nil)
      return @cache_retention_pr_branch_ttl_raw if defined?(@cache_retention_pr_branch_ttl_raw) && spec.nil?
      return nil if spec.nil?

      seconds = parse_retention_duration_seconds(spec)
      @cache_retention_pr_branch_ttl_raw = spec
      @cache_retention_pr_branch_ttl_seconds = seconds
    end

    def cache_retention_pr_branch_ttl_seconds
      return nil unless defined?(@cache_retention_pr_branch_ttl_seconds)

      @cache_retention_pr_branch_ttl_seconds
    end

    def raise_if_retention_conflict(other_method)
      other_ivar =
        case other_method
        when :cache_retention_count then :@cache_retention_count
        when :cache_retention_duration then :@cache_retention_duration_seconds
        end
      return unless instance_variable_defined?(other_ivar) && instance_variable_get(other_ivar)

      raise InvalidUsageError,
            'cache_retention_count and cache_retention_duration are mutually exclusive'
    end

    def parse_retention_duration_seconds(spec)
      case spec
      when ::Integer
        raise InvalidUsageError, 'retention duration must be positive' unless spec.positive?

        spec
      when ::String
        parse_retention_duration_from_string(spec)
      else
        raise InvalidUsageError,
              "invalid retention duration: #{spec.inspect} (expected Integer seconds or String like '30 days')"
      end
    end

    def parse_retention_duration_from_string(spec)
      match = spec.strip.match(/\A(\d+)\s+(second|minute|hour|day|week)s?\z/i)
      unless match
        raise InvalidUsageError,
              "invalid retention duration: #{spec.inspect} (expected e.g. '30 days', '2 weeks', '1 hour')"
      end

      units = { 'second' => 1, 'minute' => 60, 'hour' => 3600, 'day' => 86_400, 'week' => 604_800 }
      count = match[1].to_i
      raise InvalidUsageError, 'retention duration must be positive' unless count.positive?

      count * units[match[2].downcase]
    end

    # Deprecated in 2.0. Kept per USER_FACING_SURFACE.md §3 "deprecated
    # options keep working with one-time warnings." Migration target:
    # `remote_cache_uri` (for the URI form) or
    # `remote_cache_backend :s3, bucket:, prefix:` (for structured form).
    def reports_s3_path(s3_path = nil)
      return @reports_s3_path if defined?(@reports_s3_path) && s3_path.nil?

      warn_once_deprecation(
        :reports_s3_path,
        '`reports_s3_path` / `RSPEC_TRACER_REPORTS_S3_PATH` is deprecated in 2.0; ' \
        "use `remote_cache_uri 's3://bucket/prefix'` or `remote_cache_backend :s3, bucket:, prefix:` instead."
      )

      path = if ENV.key?('RSPEC_TRACER_REPORTS_S3_PATH')
               ENV['RSPEC_TRACER_REPORTS_S3_PATH']
             else
               s3_path
             end

      @reports_s3_path = path if valid_s3_path?(path)
    end

    # Deprecated in 2.0. Migration: `remote_cache_backend :s3, ...,
    # local: true`. Kept for backward compat; UserTasks derives the
    # `local:` opt from this when `remote_cache_backend` is absent.
    def use_local_aws(new_flag = nil)
      return @use_local_aws if defined?(@use_local_aws) && new_flag.nil?

      warn_once_deprecation(
        :use_local_aws,
        '`use_local_aws` / `RSPEC_TRACER_USE_LOCAL_AWS` is deprecated in 2.0; ' \
        'use `remote_cache_backend :s3, ..., local: true` instead.'
      )

      @use_local_aws = if ENV.key?('RSPEC_TRACER_USE_LOCAL_AWS')
                         ENV['RSPEC_TRACER_USE_LOCAL_AWS'] == 'true'
                       else
                         new_flag == true
                       end
    end

    def warn_once_deprecation(key, message)
      @_deprecation_warnings ||= {}
      return if @_deprecation_warnings.key?(key)

      @_deprecation_warnings[key] = true
      logger.warn("rspec-tracer deprecation: #{message}")
    end

    def upload_non_ci_reports(new_flag = nil)
      return @upload_non_ci_reports if defined?(@upload_non_ci_reports) && new_flag.nil?

      @upload_non_ci_reports = if ENV.key?('RSPEC_TRACER_UPLOAD_NON_CI_REPORTS')
                                 ENV['RSPEC_TRACER_UPLOAD_NON_CI_REPORTS'] == 'true'
                               else
                                 new_flag == true
                               end
    end

    def run_all_examples(new_flag = nil)
      return @run_all_examples if defined?(@run_all_examples) && new_flag.nil?

      @run_all_examples = if ENV.key?('RSPEC_TRACER_RUN_ALL_EXAMPLES')
                            ENV['RSPEC_TRACER_RUN_ALL_EXAMPLES'] == 'true'
                          else
                            new_flag == true
                          end
    end

    def fail_on_duplicates(new_flag = nil)
      return @fail_on_duplicates if defined?(@fail_on_duplicates) && new_flag.nil?

      @fail_on_duplicates = if ENV.key?('RSPEC_TRACER_FAIL_ON_DUPLICATES')
                              ENV['RSPEC_TRACER_FAIL_ON_DUPLICATES'] == 'true'
                            else
                              new_flag == true
                            end
    end

    # M3.7 transitive-load attribution (closes the constants blind
    # spot). Default `true` - the tracker observes files loaded during
    # the process and attributes them as transitive deps of every
    # subsequent example, so a change to a constants-defining file
    # correctly invalidates tests that only reference its constants.
    #
    # Setting to `false` restores 1.x behavior (pure coverage-diff).
    # Teams who explicitly accept the blind spot as a speed tradeoff
    # can opt out; the cost is silent staleness on constants edits.
    #
    # Default-true breaks the `defined? && new_flag.nil?` memo shape
    # (first read returns nil instead of true). Explicit ternary
    # handles first-call / ENV / explicit-arg cases uniformly.
    def transitive_load_tracking(new_flag = nil)
      return @transitive_load_tracking if defined?(@transitive_load_tracking) && new_flag.nil?

      @transitive_load_tracking = if ENV.key?('RSPEC_TRACER_TRANSITIVE_LOAD_TRACKING')
                                    ENV['RSPEC_TRACER_TRANSITIVE_LOAD_TRACKING'] != 'false'
                                  elsif new_flag.nil?
                                    true
                                  else
                                    new_flag == true
                                  end
    end

    # M4.2 opt-in for narrow schema attribution. Default `false` - the
    # Preset `:schema` category already declared-glob-tracks db/schema.rb
    # + db/structure.sql as a safe over-approximation (any schema change
    # re-runs every example). Calling this method opts in to an
    # `sql.active_record` subscriber that emits schema inputs only for
    # examples that actually touched AR during the run, narrowing the
    # re-run set to DB-touching examples.
    #
    # Shape: setter-only DSL (like `track_rails_defaults`, `track_files`).
    # Bare `track_ar_schema_notifications` in `.rspec-tracer` enables;
    # explicit `track_ar_schema_notifications(false)` disables for tests
    # or config overrides. Read the resulting state via the `?` variant,
    # which layers the `RSPEC_TRACER_AR_SCHEMA_NOTIFICATIONS` ENV
    # override on top of the DSL value.
    #
    # To use the narrower behavior, pair with `track_rails_defaults
    # except: [:schema]` so the declared-glob path doesn't dominate the
    # notification signal at graph registration. Leaving the Preset's
    # :schema category on alongside this flag is a no-op in terms of
    # the final re-run set - declared-glob attaches schema to every
    # example regardless of what this subscriber emits.
    def track_ar_schema_notifications(*args)
      # Setter DSL: bare call enables, explicit `(false)` disables,
      # any other positional coerces to false (defensive for typos).
      @track_ar_schema_notifications = args.empty? || args.first == true
    end

    def track_ar_schema_notifications?
      return ENV['RSPEC_TRACER_AR_SCHEMA_NOTIFICATIONS'] == 'true' if ENV.key?('RSPEC_TRACER_AR_SCHEMA_NOTIFICATIONS')
      return false unless defined?(@track_ar_schema_notifications)

      @track_ar_schema_notifications == true
    end

    def lock_file(new_file = nil)
      return @lock_file if defined?(@lock_file) && @lock_file && new_file.nil?

      @lock_file = if ENV.key?('RSPEC_TRACER_LOCK_FILE')
                     ENV['RSPEC_TRACER_LOCK_FILE']
                   else
                     new_file || DEFAULT_LOCK_FILE
                   end
    end

    def log_level(new_level = nil)
      return @log_level if defined?(@log_level) && @log_level && new_level.nil?

      level = if ENV.key?('RSPEC_TRACER_LOG_LEVEL')
                ENV['RSPEC_TRACER_LOG_LEVEL']
              else
                new_level
              end

      @logger = nil
      @log_level = LOG_LEVEL[level.to_s.to_sym].to_i
    end

    def logger
      @logger ||= RSpecTracer::Logger.new(log_level)
    end

    def coverage_track_files(glob)
      @coverage_track_files = glob
    end

    def coverage_tracked_files
      @coverage_track_files if defined?(@coverage_track_files)
    end

    # M3.3 declared-globs DSL. Accumulates every call into a single
    # array that DeclaredGlobs / NewFileDetector consume at boot.
    # Coexists with legacy `coverage_track_files` (single-arg setter,
    # overwrite-on-call) without changing that surface - see
    # `#declared_globs` for the consolidated view.
    def track_files(*globs)
      if defined?(@declared_globs_frozen) && @declared_globs_frozen
        raise InvalidUsageError,
              'track_files cannot be called after the tracker has started'
      end

      @track_files_globs ||= []
      @track_files_globs.concat(globs.flatten.compact.map(&:to_s))
      @track_files_globs
    end

    # Consolidated read-only view over `track_files` + legacy
    # `coverage_track_files`. Order: user-declared first (preserves
    # DSL call order), legacy value last. De-duplicated; frozen so
    # downstream consumers treat it as immutable.
    def declared_globs
      all = []
      all.concat(@track_files_globs) if defined?(@track_files_globs) && @track_files_globs
      all << @coverage_track_files if defined?(@coverage_track_files) && @coverage_track_files
      all.uniq.freeze
    end

    # Rails preset hook. Expands to the Rails glob set defined in
    # RSpecTracer::Rails::Preset (views, helpers, locales, config,
    # schema, factories, fixtures) and accumulates those globs into
    # `@track_files_globs`. Per-category opt-out via the `except:`
    # keyword argument (e.g. `track_rails_defaults except: [:views]`).
    #
    # Requires 'rspec_tracer/rails/preset' lazily so pure-Ruby suites
    # that never call `track_rails_defaults` do not pay for the file
    # load. Deduplication and whole-suite-invalidator reuse happen in
    # `#declared_globs` / `Tracker::WholeSuiteInvalidators`; this method
    # is intentionally idempotent on repeat calls.
    def track_rails_defaults(except: [])
      require_relative 'rails/preset'

      globs = RSpecTracer::Rails::Preset.globs(except: except)
      track_files(*globs)
    end

    # One-way latch. Tracker.setup (M3.6) flips it so a stray
    # `track_files` later in the boot sequence raises instead of
    # silently accumulating into state that has already been read.
    def freeze_declared_globs!
      @declared_globs_frozen = true
    end

    # M5.1 per-spec-file exclusion (closes upstream #41). Accumulates
    # glob patterns that match test files rspec-tracer should leave
    # alone: matching examples pass through RSpec unchanged, but the
    # tracer does not compute an identity hash, does not run
    # duplicate detection, and does not include them in any filter
    # decision. Distinct from `add_filter` - that excludes *source*
    # files from dependency attribution; `ignore_spec_files` excludes
    # *spec* files from tracer visibility entirely.
    #
    # Typical use: a smoke-test spec with intentionally duplicated
    # descriptions that rspec-tracer's `fail_on_duplicates=true`
    # gate would otherwise reject.
    #
    # Shape mirrors `track_files`: bare call returns the current
    # frozen array, any arg call accumulates.
    def ignore_spec_files(*globs)
      @ignore_spec_files_globs ||= []
      @ignore_spec_files_globs.concat(globs.flatten.compact.map(&:to_s)) unless globs.empty?
      @ignore_spec_files_globs.dup.freeze
    end

    # Runtime matcher consumed by RunnerHook. Normalizes `file_path`
    # to three candidate forms - the raw RSpec-emitted path (often
    # `./spec/foo_spec.rb`), the same with `./` stripped, and the
    # root-relative form - then compares each against each configured
    # glob via `File.fnmatch?`. Public because the RSpec hook layer
    # calls it from outside the configure block.
    def ignore_spec_file?(file_path)
      return false if file_path.nil? || file_path.empty?

      globs = defined?(@ignore_spec_files_globs) ? @ignore_spec_files_globs : nil
      return false if globs.nil? || globs.empty?

      candidates = _ignore_spec_file_candidates(file_path)
      globs.any? do |glob|
        candidates.any? { |candidate| File.fnmatch?(glob, candidate, File::FNM_PATHNAME) }
      end
    end

    def _ignore_spec_file_candidates(file_path)
      candidates = [file_path]
      stripped = file_path.delete_prefix('./')
      candidates << stripped if stripped != file_path
      relative = _relative_file_path(file_path)
      candidates << relative if relative != file_path
      candidates
    end

    def _relative_file_path(file_path)
      return file_path unless defined?(@root) && @root && file_path.start_with?("#{@root}/")

      file_path[(@root.length + 1)..]
    end

    # M3.8 local-cache run-id retention. Default 5 keeps enough
    # history for rollback debugging without letting the cache grow
    # unbounded on long-lived machines (issue #20). 0 opts out (1.x
    # behavior - dirs accumulate forever). ENV
    # RSPEC_TRACER_CACHE_RETENTION_LOCAL_COUNT wins over the DSL
    # argument, matching the other cache_* precedence conventions.
    #
    # Prune-on-save is handled by JsonBackend; this DSL just carries
    # the configured value so the engine can pass it through on
    # backend construction. One-off cleanup lives in the
    # `rspec_tracer:cache:gc` Rake task.
    # rubocop:disable Metrics/PerceivedComplexity
    def cache_retention_local_count(count = nil)
      return @cache_retention_local_count if defined?(@cache_retention_local_count) && count.nil?

      if ENV.key?('RSPEC_TRACER_CACHE_RETENTION_LOCAL_COUNT')
        env_value = ENV['RSPEC_TRACER_CACHE_RETENTION_LOCAL_COUNT']
        unless env_value.match?(/\A\d+\z/)
          raise InvalidUsageError,
                "RSPEC_TRACER_CACHE_RETENTION_LOCAL_COUNT must be a non-negative integer, got #{env_value.inspect}"
        end
        @cache_retention_local_count = env_value.to_i
      elsif count.nil?
        @cache_retention_local_count = DEFAULT_CACHE_RETENTION_LOCAL_COUNT
      elsif count.is_a?(::Integer) && count >= 0
        @cache_retention_local_count = count
      else
        raise InvalidUsageError,
              "cache_retention_local_count must be a non-negative integer, got #{count.inspect}"
      end

      @cache_retention_local_count
    end
    # rubocop:enable Metrics/PerceivedComplexity

    # M3.8 size budgets. Both return non-negative Integer MiB.
    # Shape identical to cache_retention_local_count:
    # defined-and-nil-arg returns memo, ENV wins, then DSL arg, then
    # module default. 0 disables the respective check.
    #
    # Duplicated body rather than factored to a private helper
    # because configure's alias loop would wrap the helper as a
    # public `_name` DSL surface (see
    # feedback_configure_dsl_private_leak).
    # rubocop:disable Metrics/PerceivedComplexity
    def cache_size_warn_per_file_mb(size_mb = nil)
      return @cache_size_warn_per_file_mb if defined?(@cache_size_warn_per_file_mb) && size_mb.nil?

      if ENV.key?('RSPEC_TRACER_CACHE_SIZE_WARN_PER_FILE_MB')
        env_value = ENV['RSPEC_TRACER_CACHE_SIZE_WARN_PER_FILE_MB']
        unless env_value.match?(/\A\d+\z/)
          raise InvalidUsageError,
                "RSPEC_TRACER_CACHE_SIZE_WARN_PER_FILE_MB must be a non-negative integer, got #{env_value.inspect}"
        end
        @cache_size_warn_per_file_mb = env_value.to_i
      elsif size_mb.nil?
        @cache_size_warn_per_file_mb = DEFAULT_CACHE_SIZE_WARN_PER_FILE_MB
      elsif size_mb.is_a?(::Integer) && size_mb >= 0
        @cache_size_warn_per_file_mb = size_mb
      else
        raise InvalidUsageError,
              "cache_size_warn_per_file_mb must be a non-negative integer, got #{size_mb.inspect}"
      end

      @cache_size_warn_per_file_mb
    end

    def cache_size_warn_total_mb(size_mb = nil)
      return @cache_size_warn_total_mb if defined?(@cache_size_warn_total_mb) && size_mb.nil?

      if ENV.key?('RSPEC_TRACER_CACHE_SIZE_WARN_TOTAL_MB')
        env_value = ENV['RSPEC_TRACER_CACHE_SIZE_WARN_TOTAL_MB']
        unless env_value.match?(/\A\d+\z/)
          raise InvalidUsageError,
                "RSPEC_TRACER_CACHE_SIZE_WARN_TOTAL_MB must be a non-negative integer, got #{env_value.inspect}"
        end
        @cache_size_warn_total_mb = env_value.to_i
      elsif size_mb.nil?
        @cache_size_warn_total_mb = DEFAULT_CACHE_SIZE_WARN_TOTAL_MB
      elsif size_mb.is_a?(::Integer) && size_mb >= 0
        @cache_size_warn_total_mb = size_mb
      else
        raise InvalidUsageError,
              "cache_size_warn_total_mb must be a non-negative integer, got #{size_mb.inspect}"
      end

      @cache_size_warn_total_mb
    end
    # rubocop:enable Metrics/PerceivedComplexity

    # M3.4 storage backend selector, extended in M3.8 to accept a
    # kwarg opts hash. Symbol form: `storage_backend :json` or
    # `storage_backend :sqlite`. ENV `RSPEC_TRACER_STORAGE` wins over
    # the DSL argument, matching the `cache_dir` / `coverage_dir`
    # precedence convention so CI can swap backends without editing
    # `.rspec-tracer`.
    #
    # Options (:json only):
    #   serializer: :json | :msgpack    on-disk payload format;
    #                                   ENV RSPEC_TRACER_STORAGE_SERIALIZER
    #                                   wins over the opt.
    #
    # :sqlite does not accept any opts - its storage layout is a
    # single sqlite3 file with a normalized schema; serializer
    # substitution does not apply.
    def storage_backend(name = nil, **opts)
      if defined?(@storage_backend_name) && @storage_backend_name && name.nil? && opts.empty?
        return @storage_backend_name
      end

      env = ENV.fetch('RSPEC_TRACER_STORAGE', nil)
      resolved = (env || name || DEFAULT_STORAGE_BACKEND).to_sym

      unless STORAGE_BACKEND_NAMES.include?(resolved)
        raise InvalidUsageError,
              "unknown storage backend: #{resolved.inspect}; allowed: #{STORAGE_BACKEND_NAMES.inspect}"
      end

      @storage_backend_name = resolved
      @storage_backend_opts = validate_and_resolve_storage_opts(resolved, opts).freeze
      @storage_backend_name
    end

    # Accessor for the opts hash passed to `storage_backend`.
    # Returns a frozen empty Hash when the DSL was called without
    # opts (or not called at all) so the backend dispatch can splat
    # `**storage_backend_opts` unconditionally.
    def storage_backend_opts
      return EMPTY_STORAGE_BACKEND_OPTS unless defined?(@storage_backend_opts) && @storage_backend_opts

      @storage_backend_opts
    end

    EMPTY_STORAGE_BACKEND_OPTS = {}.freeze
    private_constant :EMPTY_STORAGE_BACKEND_OPTS

    def validate_and_resolve_storage_opts(backend, opts)
      unknown = opts.keys - STORAGE_BACKEND_OPT_KEYS
      unless unknown.empty?
        raise InvalidUsageError,
              "unknown storage_backend options: #{unknown.inspect}; allowed: #{STORAGE_BACKEND_OPT_KEYS.inspect}"
      end

      if backend == :sqlite && !opts.empty?
        raise InvalidUsageError,
              "storage_backend :sqlite does not accept options (got #{opts.keys.inspect})"
      end

      return {} unless backend == :json

      env_ser = ENV.fetch('RSPEC_TRACER_STORAGE_SERIALIZER', nil)
      serializer = (env_ser || opts[:serializer] || :json).to_sym

      unless STORAGE_BACKEND_SERIALIZERS.include?(serializer)
        raise InvalidUsageError,
              "unknown storage serializer: #{serializer.inspect}; allowed: #{STORAGE_BACKEND_SERIALIZERS.inspect}"
      end

      { serializer: serializer }
    end

    # M6.1 reporter DSL. Accumulates each call onto an internal list of
    # `[name_or_class, opts]` pairs that `Reporters::Registry` walks
    # at finalize-time. Matches the `track_files` accumulator shape.
    #
    # Shapes:
    #   add_reporter :terminal
    #   add_reporter :json
    #   add_reporter MyCustomReporter, color: false
    #
    # Symbol names must match `Reporters::Registry::BUILT_INS.keys`
    # (`:terminal`, `:json`; M6.2 adds `:html`). Class values are
    # trusted - they must subclass / duck-type `Reporters::Base` but
    # validation is deferred to initialize-time so custom reporters
    # defined in user code don't have to exist at DSL-validate time.
    #
    # If the user never calls `add_reporter`, `Registry.emit_all`
    # falls back to `Registry::DEFAULTS` (`[:terminal, :json]`).
    def add_reporter(name_or_class, **opts)
      validate_reporter_entry(name_or_class)
      @reporters ||= []
      @reporters << [name_or_class, opts]
      @reporters.dup.freeze
    end

    # Readonly access to the accumulated reporter entries. Returns
    # `nil` when no `add_reporter` calls were made - the Registry
    # distinguishes nil (fall back to defaults) from `[]` (user
    # opted out of every reporter).
    def reporters
      return nil unless defined?(@reporters)

      @reporters.dup.freeze
    end

    def validate_reporter_entry(name_or_class)
      case name_or_class
      when ::Symbol
        allowed = reporter_builtins_keys
        return if allowed.include?(name_or_class)

        raise InvalidUsageError,
              "unknown reporter: #{name_or_class.inspect}; allowed: #{allowed.inspect}"
      when ::Class
        nil
      else
        raise InvalidUsageError,
              "add_reporter: expected Symbol or Class, got #{name_or_class.class}"
      end
    end

    def reporter_builtins_keys
      return [] unless defined?(RSpecTracer::Reporters::Registry)

      RSpecTracer::Reporters::Registry::BUILT_INS.keys
    end

    def add_filter(filter = nil, &)
      filters << parse_filter(filter, &)
    end

    def filters
      @filters ||= []
    end

    def filters=(new_filteres)
      raise NotImplementedError
    end

    def add_coverage_filter(filter = nil, &)
      coverage_filters << parse_filter(filter, &)
    end

    def coverage_filters
      @coverage_filters ||= []
    end

    def coverage_filters=(new_filteres)
      raise NotImplementedError
    end

    def valid_s3_path?(s3_path)
      uri = URI.parse(s3_path)

      uri.scheme == 's3' && !uri.host.empty?
    rescue URI::InvalidURIError => _e
      false
    end

    def parallel_tests_id
      if ParallelTests.first_process?
        'parallel_tests_1'
      else
        "parallel_tests_#{ENV.fetch('TEST_ENV_NUMBER', nil)}"
      end
    end

    def parse_filter(filter = nil, &block)
      arg = filter || block

      raise ArgumentError, 'Either a filter or a block required' if arg.nil?

      RSpecTracer::Filter.register(arg)
    end
  end
  # rubocop:enable Metrics/ModuleLength
end
