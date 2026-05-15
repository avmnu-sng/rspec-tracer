# frozen_string_literal: true

require 'uri'

require_relative 'filter'
require_relative 'logger'

module RSpecTracer
  # The user-facing configuration DSL. Mixed into `RSpecTracer` itself,
  # so calls inside a `.rspec-tracer` (or `~/.rspec-tracer`) file appear
  # against the top-level module:
  #
  # @example A typical `.rspec-tracer`
  #   RSpecTracer.configure do
  #     project_name 'My App'
  #     track_files 'config/locales/**/*.yml', 'db/schema.rb', 'Gemfile.lock'
  #     track_env   'AUTH_TOKEN', 'DATABASE_URL', 'RAILS_*'
  #     track_rails_defaults
  #
  #     storage_backend :sqlite
  #     remote_cache_backend :s3, bucket: 'my-bucket', prefix: 'rspec-tracer'
  #
  #     add_filter '/vendor/'
  #     add_coverage_filter %w[/spec/ /test/]
  #   end
  #
  # The DSL methods are technically `private` in Ruby; the `configure`
  # block uses Docile to expose them as if public. Calling them
  # outside a `.rspec-tracer` file raises `InvalidUsageError`. The
  # configuration loader allowlist enforces this gate (see
  # {ALLOWED_CONFIGURER}).
  #
  # See also:
  # - {file:README.md} — user guide.
  # - {file:UPGRADING.md} — 1.x → 2.0 migration.
  # - {file:ARCHITECTURE.md} — input taxonomy + layer structure.
  # - {file:COOKBOOK.md} — recipes for common scenarios.
  #
  # rubocop:disable Metrics/ModuleLength
  module Configuration
    # Raised when the configuration DSL is invoked outside a
    # `.rspec-tracer` / `~/.rspec-tracer` loader, when a typo'd DSL
    # method is called (with a `did_you_mean?` suggestion when one
    # exists), or when an option value fails validation.
    class InvalidUsageError < StandardError; end

    # Internal constant.
    # @api private
    ALLOWED_CONFIGURER = %w[
      lib/rspec_tracer/load_default_config.rb
      lib/rspec_tracer/load_global_config.rb
      lib/rspec_tracer/load_local_config.rb
    ].freeze

    # Internal constant.
    # @api private
    DEFAULT_CACHE_DIR = 'rspec_tracer_cache'
    # Internal constant.
    # @api private
    DEFAULT_COVERAGE_DIR = 'rspec_tracer_coverage'
    # Internal constant.
    # @api private
    DEFAULT_REPORT_DIR = 'rspec_tracer_report'
    # Internal constant.
    # @api private
    DEFAULT_LOCK_FILE = 'rspec_tracer.lock'
    # Internal constant.
    # @api private
    DEFAULT_STORAGE_BACKEND = :json
    # :sqlite opt-in: MRI >= 3.2 only (sqlite3 2.x gem requirement).
    # Kept closed so typos raise early.
    STORAGE_BACKEND_NAMES = %i[json sqlite].freeze
    # Keys allowed in `storage_backend`'s opts hash. `:serializer` is
    # accepted only for the :json backend (see validate_storage_opts!).
    STORAGE_BACKEND_OPT_KEYS = %i[serializer].freeze
    # Internal constant.
    # @api private
    STORAGE_BACKEND_SERIALIZERS = %i[json msgpack].freeze
    # Default Ruby `Coverage` modes when the user has not called the
    # `coverage_modes` DSL. Matches bare `Coverage.start` semantics so
    # legacy configs continue to emit lines-only `coverage.json` shape.
    DEFAULT_COVERAGE_MODES = %i[lines].freeze
    # Allowed Ruby `Coverage` modes accepted by the `coverage_modes`
    # DSL. The set tracks Ruby 3.1+ `Coverage.start` keyword args.
    # `coverage.json` ships the lines-only `Array<Integer|nil>` shape
    # per file regardless — branches / methods / oneshot_lines / eval
    # data is collected by Ruby but the user-facing artifact stays on
    # the documented 1.x shape (see UPGRADING `#SimpleCov branch
    # coverage now works` for SimpleCov interop).
    COVERAGE_MODES = %i[lines branches methods oneshot_lines eval].freeze
    # Per-save retention on the local cache's run-id directories.
    # 5 keeps enough history for rollback debugging without letting
    # the cache grow unbounded (issue #20). 0 opts out entirely.
    DEFAULT_CACHE_RETENTION_LOCAL_COUNT = 5
    # Size budgets (MiB). Warn at save time when any single cache
    # file exceeds the per-file threshold or when the cache total
    # exceeds the aggregate threshold. Surfaces dependency.json
    # ballooning past the few-MB range while the user can still
    # act on them. Set to 0 to disable either individually.
    DEFAULT_CACHE_SIZE_WARN_PER_FILE_MB = 50
    # Internal constant.
    # @api private
    DEFAULT_CACHE_SIZE_WARN_TOTAL_MB = 500

    # Internal constant.
    # @api private
    LOG_LEVEL = {
      off: 0,
      debug: 1,
      info: 2,
      warn: 3,
      error: 4
    }.freeze

    # Internal method on the tracer pipeline.
    # @api private
    def configure(&)
      # Scan the full caller chain (not just the immediate two frames):
      # MRI / JRuby place the load_*_config.rb loader at depth 2, but
      # TruffleRuby's `load` interposes an extra runtime frame, pushing
      # the loader past the 2-frame window and tripping the InvalidUsage
      # raise. Path-suffix match against the well-known loader filenames
      # keeps the gate safe regardless of stack depth - user code would
      # have to copy one of those filenames verbatim into a path it
      # `load`s to get a false positive, which we treat as wilful.
      configurers = caller_locations(1).map(&:path)
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
          # `storage_backend :json, serializer: :msgpack`). Earlier
          # forms of this wrapper forwarded `*args, &block` only and
          # silently stripped kwargs.
          define_method method_name do |*args, **kwargs, &block|
            send(:"_#{method_name}", *args, **kwargs, &block)
          end
        end
      end

      Docile.dsl_eval(self, &)
    end

    private

    # Set the project root directory. Defaults to `Dir.getwd`.
    # Affects how all other path-based DSL methods (`cache_dir`,
    # `report_dir`, `coverage_dir`, `track_files` globs) are
    # resolved.
    #
    # @param root [String, nil] absolute or relative path; nil
    #   returns the current value (or default).
    # @return [String] absolute project root path.
    # @example
    #   RSpecTracer.configure { root '/path/to/project' }
    def root(root = nil)
      return @root if defined?(@root) && root.nil?

      @cache_path = nil
      @report_path = nil
      @coverage_path = nil

      @root = File.expand_path(root || Dir.getwd)
    end

    # Set the project's display name; appears in HTML reports.
    # Defaults to a humanized form of the project root's basename.
    #
    # @param new_name [String, nil] human-readable project name.
    # @return [String] the configured (or derived) project name.
    def project_name(new_name = nil)
      return @project_name if defined?(@project_name) && @project_name && new_name.nil?

      @project_name = new_name if new_name.is_a?(String)
      @project_name ||= File.basename(root.split('/').last).capitalize.tr('_', ' ')
    end

    # Override the on-disk cache directory (default
    # `rspec_tracer_cache`). Also reads `RSPEC_TRACER_CACHE_DIR`
    # from env when set. The directory ships in the canonical
    # `.gitignore` recipe; renaming silently leaks cache into
    # source control.
    #
    # @param dir [String, nil] relative-to-root or absolute path.
    # @return [String] configured cache directory.
    def cache_dir(dir = nil)
      return @cache_dir if defined?(@cache_dir) && dir.nil?

      @cache_path = nil
      @cache_dir = if ENV.key?('RSPEC_TRACER_CACHE_DIR')
                     ENV['RSPEC_TRACER_CACHE_DIR']
                   else
                     dir || DEFAULT_CACHE_DIR
                   end
    end

    # Resolve the absolute cache path; expanded against {#root} and
    # scoped per `TEST_SUITE_ID` / `parallel_tests` worker. Creates
    # the directory on first access.
    #
    # @return [String] absolute cache path.
    def cache_path
      @cache_path ||= begin
        cache_path = File.expand_path(cache_dir, root)
        cache_path = File.join(cache_path, ENV['TEST_SUITE_ID'].to_s) if ENV['TEST_SUITE_ID']
        cache_path = File.join(cache_path, parallel_tests_id) if RSpecTracer.parallel_tests?

        FileUtils.mkdir_p(cache_path)

        cache_path
      end
    end

    # Override the on-disk HTML/JSON report directory (default
    # `rspec_tracer_report`). Also reads `RSPEC_TRACER_REPORT_DIR`.
    #
    # @param dir [String, nil] relative-to-root or absolute path.
    # @return [String] configured report directory.
    def report_dir(dir = nil)
      return @report_dir if defined?(@report_dir) && dir.nil?

      @report_path = nil
      @report_dir = if ENV.key?('RSPEC_TRACER_REPORT_DIR')
                      ENV['RSPEC_TRACER_REPORT_DIR']
                    else
                      dir || DEFAULT_REPORT_DIR
                    end
    end

    # Resolve the absolute report path; expanded against {#root} and
    # scoped per `TEST_SUITE_ID` / `parallel_tests` worker. Creates
    # the directory on first access.
    #
    # @return [String] absolute report path.
    def report_path
      @report_path ||= begin
        report_path = File.expand_path(report_dir, root)
        report_path = File.join(report_path, ENV['TEST_SUITE_ID'].to_s) if ENV['TEST_SUITE_ID']
        report_path = File.join(report_path, parallel_tests_id) if RSpecTracer.parallel_tests?

        FileUtils.mkdir_p(report_path)

        report_path
      end
    end

    # Override the coverage output directory (default
    # `rspec_tracer_coverage`). Also reads `RSPEC_TRACER_COVERAGE_DIR`.
    #
    # @param dir [String, nil] relative-to-root or absolute path.
    # @return [String] configured coverage directory.
    def coverage_dir(dir = nil)
      return @coverage_dir if defined?(@coverage_dir) && dir.nil?

      @coverage_path = nil
      @coverage_dir = if ENV.key?('RSPEC_TRACER_COVERAGE_DIR')
                        ENV['RSPEC_TRACER_COVERAGE_DIR']
                      else
                        dir || DEFAULT_COVERAGE_DIR
                      end
    end

    # Resolve the absolute coverage path; expanded against {#root}
    # and scoped per `TEST_SUITE_ID` / `parallel_tests` worker.
    # Creates the directory on first access.
    #
    # @return [String] absolute coverage path.
    def coverage_path
      @coverage_path ||= begin
        coverage_path = File.expand_path(coverage_dir, root)
        coverage_path = File.join(coverage_path, ENV['TEST_SUITE_ID'].to_s) if ENV['TEST_SUITE_ID']
        coverage_path = File.join(coverage_path, parallel_tests_id) if RSpecTracer.parallel_tests?

        FileUtils.mkdir_p(coverage_path)

        coverage_path
      end
    end

    # Configure the remote-cache backend used by the
    # `rake rspec_tracer:remote_cache:download` / `:upload` tasks.
    # Single-entry accumulator: a second call raises
    # {InvalidUsageError} so a misconfigured `.rspec-tracer` fails
    # fast.
    #
    # @param name_or_class [Symbol, Class] one of `:s3`, `:local_fs`,
    #   `:redis`, OR a custom class implementing
    #   {RSpecTracer::RemoteCache::Backend}.
    # @param opts [Hash] backend-specific keyword args (e.g. `bucket:`
    #   `prefix:` for `:s3`; `root:` for `:local_fs`; `url:` `ttl:`
    #   for `:redis`).
    # @return [Array(Symbol, Hash)] the persisted entry pair.
    # @example S3 (preserves the 1.x layout)
    #   remote_cache_backend :s3, bucket: 'my-bucket', prefix: 'rspec-tracer'
    # @example LocalStack / awslocal (development)
    #   remote_cache_backend :s3, bucket: 'my-bucket', prefix: 'x', local: true
    # @example Filesystem-backed (no S3 needed)
    #   remote_cache_backend :local_fs, root: '/tmp/rspec-tracer-cache'
    # @example Redis (with TTL + PR-branch tracking sidecar)
    #   remote_cache_backend :redis, url: ENV['REDIS_URL'], ttl: 7 * 86_400
    # @example Custom backend class
    #   remote_cache_backend MyCustomBackend, custom_opt: 'value'
    def remote_cache_backend(name_or_class, **opts)
      if defined?(@remote_cache_backend_entry) && @remote_cache_backend_entry
        raise InvalidUsageError,
              'remote_cache already configured. `remote_cache_backend` and ' \
              '`remote_cache_uri` are alternative DSLs — call one exactly once.'
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

    # Internal method on the tracer pipeline.
    # @api private
    def validate_remote_cache_backend(name_or_class)
      case name_or_class
      when ::Symbol, ::Class
        nil
      else
        raise InvalidUsageError,
              "remote_cache_backend: expected Symbol or Class, got #{name_or_class.class}"
      end
    end

    # Convenience DSL accepting a single URI string and dispatching
    # to {#remote_cache_backend} with the parsed bucket / prefix /
    # host / path. Also reads `RSPEC_TRACER_REMOTE_CACHE_URI` from env.
    #
    # @param uri [String, nil] one of `s3://bucket/prefix`,
    #   `file:///abs/path`, `redis://host:port/db`. Pass nil to read
    #   the env var (or return the cached value if set).
    # @return [String, nil] the configured URI, or nil when neither
    #   arg nor env is set.
    # @example
    #   remote_cache_uri 's3://my-bucket/rspec-tracer'
    # @example
    #   remote_cache_uri 'file:///tmp/rspec-tracer-cache'
    # @example
    #   remote_cache_uri 'redis://localhost:6379/0'
    #
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

    # Internal method on the tracer pipeline.
    # @api private
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

    # Internal method on the tracer pipeline.
    # @api private
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
    # Cap remote-cache main-tier refs to a count. Mutually exclusive
    # with {#cache_retention_duration}; setting both raises.
    #
    # @param count [Integer, nil] positive integer; nil reads current
    #   value.
    # @return [Integer, nil] configured count.
    # @raise [InvalidUsageError] when count is non-positive or when
    #   {#cache_retention_duration} is already set.
    def cache_retention_count(count = nil)
      return @cache_retention_count if defined?(@cache_retention_count) && count.nil?
      return nil if count.nil?

      raise_if_retention_conflict(:cache_retention_duration)
      unless count.is_a?(::Integer) && count.positive?
        raise InvalidUsageError, "cache_retention_count must be a positive integer, got #{count.inspect}"
      end

      @cache_retention_count = count
    end

    # Cap remote-cache main-tier refs by age. Mutually exclusive with
    # {#cache_retention_count}; setting both raises.
    #
    # @param spec [String, Integer, nil] duration string (e.g.
    #   `'7d'`, `'48h'`, `'30m'`) OR seconds as integer. nil reads
    #   current.
    # @return [String, Integer, nil] configured raw spec.
    # @raise [InvalidUsageError] when spec is unparseable or when
    #   {#cache_retention_count} is already set.
    def cache_retention_duration(spec = nil)
      return @cache_retention_duration_raw if defined?(@cache_retention_duration_raw) && spec.nil?
      return nil if spec.nil?

      raise_if_retention_conflict(:cache_retention_count)
      seconds = parse_retention_duration_seconds(spec)
      @cache_retention_duration_raw = spec
      @cache_retention_duration_seconds = seconds
    end

    # @return [Integer, nil] {#cache_retention_duration} expressed
    #   in seconds, or nil if not set.
    def cache_retention_duration_seconds
      return nil unless defined?(@cache_retention_duration_seconds)

      @cache_retention_duration_seconds
    end

    # Cap remote-cache PR-tier refs by age. Independent of main-tier
    # retention (PR branches typically need shorter TTLs than the
    # historical main).
    #
    # @param spec [String, Integer, nil] duration string or seconds.
    # @return [String, Integer, nil] configured raw spec.
    def cache_retention_pr_branch_ttl(spec = nil)
      return @cache_retention_pr_branch_ttl_raw if defined?(@cache_retention_pr_branch_ttl_raw) && spec.nil?
      return nil if spec.nil?

      seconds = parse_retention_duration_seconds(spec)
      @cache_retention_pr_branch_ttl_raw = spec
      @cache_retention_pr_branch_ttl_seconds = seconds
    end

    # @return [Integer, nil] {#cache_retention_pr_branch_ttl}
    #   expressed in seconds.
    def cache_retention_pr_branch_ttl_seconds
      return nil unless defined?(@cache_retention_pr_branch_ttl_seconds)

      @cache_retention_pr_branch_ttl_seconds
    end

    # Internal method on the tracer pipeline.
    # @api private
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

    # Internal method on the tracer pipeline.
    # @api private
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

    # Internal method on the tracer pipeline.
    # @api private
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

    # Deprecated in 2.0. Kept per USER_FACING_SURFACE.md section 3 "deprecated
    # options keep working with one-time warnings." Migration target:
    # `remote_cache_uri` (for the URI form) or
    # `remote_cache_backend :s3, bucket:, prefix:` (for structured form).
    # @deprecated Use {#remote_cache_uri} or {#remote_cache_backend}.
    #   Pre-2.0 1.x compatibility shim. Fires a one-time `logger.warn`
    #   at first use; the value still resolves so 1.x configs keep
    #   working until the 3.0 removal.
    # @param s3_path [String, nil] `s3://bucket/prefix`.
    # @return [String, nil]
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

    # Probe-path predicate. True when the user explicitly set
    # `reports_s3_path` via the DSL OR the `RSPEC_TRACER_REPORTS_S3_PATH`
    # environment variable. Distinct from {#reports_s3_path} (the
    # getter), which fires a one-time deprecation warning on every
    # call from an unconfigured state — including the
    # `RemoteCache::UserTasks#derive_from_legacy_dsl` probe that runs
    # whenever any `rake rspec_tracer:remote_cache:*` task fires.
    # Callers that need to detect whether the legacy DSL was actually
    # used (vs probing) should read this predicate first.
    #
    # @return [Boolean]
    def reports_s3_path_set?
      return true if defined?(@reports_s3_path) && @reports_s3_path
      return false unless ENV.key?('RSPEC_TRACER_REPORTS_S3_PATH')

      env_value = ENV.fetch('RSPEC_TRACER_REPORTS_S3_PATH', nil)
      !env_value.nil? && !env_value.empty?
    end

    # Deprecated in 2.0. Migration: `remote_cache_backend :s3, ...,
    # local: true`. Kept for backward compat; UserTasks derives the
    # `local:` opt from this when `remote_cache_backend` is absent.
    # @deprecated Use `remote_cache_backend :s3, ..., local: true`.
    #   Pre-2.0 1.x compatibility shim for `awslocal` / LocalStack.
    #   Fires a one-time `logger.warn` at first use.
    # @param new_flag [Boolean, nil]
    # @return [Boolean]
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

    # Internal method on the tracer pipeline.
    # @api private
    def warn_once_deprecation(key, message)
      @_deprecation_warnings ||= {}
      return if @_deprecation_warnings.key?(key)

      @_deprecation_warnings[key] = true
      logger.warn("rspec-tracer deprecation: #{message}")
    end

    # Allow remote-cache uploads from non-CI environments (default
    # `false`). Reads `RSPEC_TRACER_UPLOAD_NON_CI_REPORTS=true` as
    # an alternate enable.
    #
    # @param new_flag [Boolean, nil]
    # @return [Boolean]
    def upload_non_ci_reports(new_flag = nil)
      return @upload_non_ci_reports if defined?(@upload_non_ci_reports) && new_flag.nil?

      @upload_non_ci_reports = if ENV.key?('RSPEC_TRACER_UPLOAD_NON_CI_REPORTS')
                                 ENV['RSPEC_TRACER_UPLOAD_NON_CI_REPORTS'] == 'true'
                               else
                                 new_flag == true
                               end
    end

    # Force every example to run (default `false` — the tracer's
    # whole point is to skip unaffected examples). Reads
    # `RSPEC_TRACER_RUN_ALL_EXAMPLES=true` as an alternate enable.
    # Useful for one-off "rebaseline the cache" runs.
    #
    # @param new_flag [Boolean, nil]
    # @return [Boolean]
    def run_all_examples(new_flag = nil)
      return @run_all_examples if defined?(@run_all_examples) && new_flag.nil?

      @run_all_examples = if ENV.key?('RSPEC_TRACER_RUN_ALL_EXAMPLES')
                            ENV['RSPEC_TRACER_RUN_ALL_EXAMPLES'] == 'true'
                          else
                            new_flag == true
                          end
    end

    # Exit with non-zero when duplicate-identity examples are
    # detected (default `true` — duplicates break per-example
    # attribution). Reads `RSPEC_TRACER_FAIL_ON_DUPLICATES=false` as
    # an alternate disable.
    #
    # @param new_flag [Boolean, nil]
    # @return [Boolean]
    def fail_on_duplicates(new_flag = nil)
      return @fail_on_duplicates if defined?(@fail_on_duplicates) && new_flag.nil?

      @fail_on_duplicates = if ENV.key?('RSPEC_TRACER_FAIL_ON_DUPLICATES')
                              ENV['RSPEC_TRACER_FAIL_ON_DUPLICATES'] == 'true'
                            else
                              new_flag == true
                            end
    end

    # Transitive-load attribution (closes the constants blind
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

    # Opt-in for narrow schema attribution. Default `false` - the
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
    # Setter DSL — bare call enables, explicit `(false)` disables.
    # Any other positional value coerces to disabled (defensive for
    # typos). Read the resulting state via {#track_ar_schema_notifications?}.
    #
    # @param args [Array] positional args (bare = enable; `false` =
    #   disable; anything else = disable defensively).
    # @return [Boolean]
    # @note **Common Rails setups widen this to whole-suite-on-schema-
    #   change.** Per-example AR cleanup mechanisms
    #   (`use_transactional_fixtures = true`, DatabaseCleaner
    #   `:truncation` / `:deletion` / `:transaction`) fire
    #   `sql.active_record` inside the per-example bucket, attributing
    #   `db/schema.rb` to every AR-touching example. A boot-time warn
    #   fires when the precondition isn't met. See README "Narrow
    #   AR-schema attribution".
    def track_ar_schema_notifications(*args)
      # Setter DSL: bare call enables, explicit `(false)` disables,
      # any other positional coerces to false (defensive for typos).
      @track_ar_schema_notifications = args.empty? || args.first == true
    end

    # Reads the resolved AR-schema-notifications state. The
    # `RSPEC_TRACER_AR_SCHEMA_NOTIFICATIONS` env var overrides the
    # DSL value when set.
    #
    # @return [Boolean]
    def track_ar_schema_notifications?
      return ENV['RSPEC_TRACER_AR_SCHEMA_NOTIFICATIONS'] == 'true' if ENV.key?('RSPEC_TRACER_AR_SCHEMA_NOTIFICATIONS')
      return false unless defined?(@track_ar_schema_notifications)

      @track_ar_schema_notifications == true
    end

    # Override the parallel_tests lock-file path (default
    # `rspec_tracer.lock`). Reads `RSPEC_TRACER_LOCK_FILE`.
    #
    # @param new_file [String, nil]
    # @return [String]
    def lock_file(new_file = nil)
      return @lock_file if defined?(@lock_file) && @lock_file && new_file.nil?

      @lock_file = if ENV.key?('RSPEC_TRACER_LOCK_FILE')
                     ENV['RSPEC_TRACER_LOCK_FILE']
                   else
                     new_file || DEFAULT_LOCK_FILE
                   end
    end

    # Set the tracer's log level. Reads `RSPEC_TRACER_LOG_LEVEL`.
    #
    # @param new_level [Symbol, String, nil] one of `:off`, `:debug`,
    #   `:info`, `:warn`, `:error`. Default `:info`.
    # @return [Integer] numeric level (LOG_LEVEL constant value).
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

    # Lazy-initialized {RSpecTracer::Logger} instance honoring
    # {#log_level}.
    #
    # @return [RSpecTracer::Logger]
    def logger
      @logger ||= RSpecTracer::Logger.new(log_level)
    end

    # Track files for SimpleCov coverage emission only (NOT for the
    # tracer's per-example dependency graph). Use {#track_files} for
    # the dependency graph.
    #
    # @param glob [String] file glob pattern.
    # @return [String]
    def coverage_track_files(glob)
      @coverage_track_files = glob
    end

    # @return [String, nil] the configured {#coverage_track_files} value.
    def coverage_tracked_files
      @coverage_track_files if defined?(@coverage_track_files)
    end

    # Declare globs of files every example depends on (e.g.
    # `Gemfile.lock`, `db/schema.rb`, `config/locales/**/*.yml`).
    # Globs accumulate across calls; the tracker resolves matched
    # files at boot and attaches them as `:declared`-kind inputs
    # to every example. For files only specific examples depend on,
    # use the per-example `tracks: { files: '...' }` metadata DSL.
    #
    # @param globs [Array<String>] file glob patterns (each matched
    #   via `Dir.glob` with `FNM_PATHNAME | FNM_EXTGLOB`).
    # @return [Array<String>] the accumulated glob list.
    # @raise [InvalidUsageError] if called after the tracker started.
    # @example
    #   track_files 'config/locales/**/*.yml', 'db/schema.rb', 'Gemfile.lock'
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

    # Rails preset — attaches the common Rails-side declared globs in
    # one DSL call. Expands to the glob set defined in
    # `RSpecTracer::Rails::Preset` (views, helpers, locales, config,
    # schema, factories, fixtures).
    #
    # @param except [Array<Symbol>] categories to opt out of (so a
    #   per-example subscriber attributes them instead). Common
    #   recipe: `track_rails_defaults except: [:views, :schema]`
    #   pairs with {#track_ar_schema_notifications} for narrow
    #   per-example schema attribution.
    # @return [Array<String>] the resulting accumulated glob list.
    # @example Default — all categories on
    #   track_rails_defaults
    # @example Opt out of views + schema for per-example subscribers
    #   track_rails_defaults except: [:views, :schema]
    #   track_ar_schema_notifications
    def track_rails_defaults(except: [])
      require_relative 'rails/preset'

      globs = RSpecTracer::Rails::Preset.globs(except: except)
      track_files(*globs)
    end

    # One-way latch. Tracker.setup flips it so a stray
    # `track_files` later in the boot sequence raises instead of
    # silently accumulating into state that has already been read.
    def freeze_declared_globs!
      @declared_globs_frozen = true
    end

    # Config-level env-tracking DSL. Accumulates names across
    # calls; bare entries flow into `Engine#setup`, are wildcard-
    # expanded via `Tracker::EnvMatcher`, and attach to every
    # previously-seen example (parallel to `track_files`'s "declared
    # globs attach to every example" semantics).
    #
    # Wildcards: single trailing (`PREFIX_*`) or single leading
    # (`*_SUFFIX`) only; `*` alone matches every env key. Multi-`*`,
    # character classes, `?`, `!`, `\\` raise ArgumentError at run
    # start (Engine#setup) so users see config errors immediately.
    #
    # Returns a frozen Array view (mirrors `ignore_spec_files` /
    # `add_reporter` shape — defensive against callers mutating an
    # internal accumulator). Setter raises if called after
    # `freeze_declared_globs!` flipped the latch (same "tracker has
    # started, no more declarations" contract as `track_files`).
    # Declare env vars every example depends on. Wildcards expand
    # against the live ENV at config load. For env vars only specific
    # examples branch on, use the per-example
    # `tracks: { env: '...' }` metadata DSL.
    #
    # @param names [Array<String, Symbol>] literal env names OR
    #   single-wildcard patterns (`'PREFIX_*'`, `'*_SUFFIX'`, `'*'`).
    # @return [Array<String>] frozen accumulated names list.
    # @raise [InvalidUsageError] if called after the tracker started,
    #   or if a pattern is malformed (multi-segment wildcards like
    #   `'A_*_B'`, character classes, etc. are rejected).
    # @example
    #   track_env 'AUTH_TOKEN', 'DATABASE_URL', 'RAILS_*', '*_API_KEY'
    def track_env(*names)
      if defined?(@declared_globs_frozen) && @declared_globs_frozen
        raise InvalidUsageError,
              'track_env cannot be called after the tracker has started'
      end

      @track_env_names ||= []
      @track_env_names.concat(names.flatten.compact.map(&:to_s))
      @track_env_names.dup.freeze
    end

    # Reader for the accumulated config-level env names. Returns a
    # frozen Array (`[].freeze` when never set), parallel to
    # `declared_globs`'s shape.
    def tracked_env_names
      return EMPTY_TRACKED_ENV_NAMES unless defined?(@track_env_names) && @track_env_names

      @track_env_names.dup.freeze
    end

    # Internal constant.
    # @api private
    EMPTY_TRACKED_ENV_NAMES = [].freeze
    private_constant :EMPTY_TRACKED_ENV_NAMES

    # Per-spec-file exclusion (closes upstream #41). Accumulates
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

    # Internal method on the tracer pipeline.
    # @api private
    def _ignore_spec_file_candidates(file_path)
      candidates = [file_path]
      stripped = file_path.delete_prefix('./')
      candidates << stripped if stripped != file_path
      relative = _relative_file_path(file_path)
      candidates << relative if relative != file_path
      candidates
    end

    # Internal method on the tracer pipeline.
    # @api private
    def _relative_file_path(file_path)
      return file_path unless defined?(@root) && @root && file_path.start_with?("#{@root}/")

      file_path[(@root.length + 1)..]
    end

    # Local-cache run-id retention. Default 5 keeps enough
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

    # Size budgets. Both return non-negative Integer MiB.
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

    # Internal method on the tracer pipeline.
    # @api private
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

    # Storage backend selector with optional kwarg opts hash.
    # Symbol form: `storage_backend :json` or
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
    # Configure the on-disk storage backend. Reads
    # `RSPEC_TRACER_STORAGE` for env-based override.
    #
    # @param name [Symbol, nil] one of `:json` (default; preserves
    #   1.x layout) or `:sqlite` (single-file DB; MRI 3.2+ only;
    #   JRuby auto-falls-back to `:json` with a one-time warn).
    # @param opts [Hash] backend-specific opts. `:json` accepts
    #   `serializer:` (`:json` default or `:msgpack`); `:sqlite`
    #   accepts no opts.
    # @return [Symbol] the resolved backend name.
    # @raise [InvalidUsageError] for unknown backend names or
    #   invalid opts.
    # @example JSON (default)
    #   storage_backend :json
    # @example SQLite (faster cold reads above ~5,000 examples)
    #   storage_backend :sqlite
    # @example JSON with msgpack serializer
    #   storage_backend :json, serializer: :msgpack
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

    # Internal constant.
    # @api private
    EMPTY_STORAGE_BACKEND_OPTS = {}.freeze
    private_constant :EMPTY_STORAGE_BACKEND_OPTS

    # Configure which Ruby `Coverage` modes rspec-tracer enables on
    # the standalone path (when SimpleCov is not running). Pass a
    # Symbol Array drawn from {COVERAGE_MODES}; `coverage_modes [:lines,
    # :branches]` translates to `Coverage.start(lines: true, branches:
    # true)`.
    #
    # When SimpleCov is loaded and running at `RSpecTracer.start`
    # time, the DSL is inert — SimpleCov owns `Coverage.start` and
    # controls modes via its own `enable_coverage :branch` etc. (the
    # documented load-order contract; see UPGRADING `#SimpleCov branch
    # coverage now works`).
    #
    # The default `[:lines]` matches the pre-#195 bare `Coverage.start`
    # semantics so existing configs continue to emit the lines-only
    # `coverage.json` shape. The `coverage.json` artifact itself stays
    # on the 1.x `Array<Integer|nil>` per-file format regardless of
    # modes (storage-format stability). Branches / methods / etc.
    # data is available to SimpleCov via the documented interop and
    # to downstream consumers via `Coverage.peek_result` directly.
    #
    # @param modes [Array<Symbol>, Symbol, nil] one or more entries
    #   from {COVERAGE_MODES} (`:lines`, `:branches`, `:methods`,
    #   `:oneshot_lines`, `:eval`); a single Symbol is wrapped to
    #   an Array.
    # @return [Array<Symbol>] the resolved (frozen) modes array. The
    #   no-arg call returns the current setting (or
    #   {DEFAULT_COVERAGE_MODES} if unset).
    # @raise [InvalidUsageError] when `modes` is empty or contains an
    #   unknown mode.
    # @example Branch coverage on top of the default lines
    #   coverage_modes [:lines, :branches]
    # @example Methods coverage in addition (for downstream tooling)
    #   coverage_modes [:lines, :methods]
    def coverage_modes(*args)
      return read_coverage_modes if args.empty?

      modes_array = Array(args.length == 1 ? args.first : args).flatten.map(&:to_sym)
      raise InvalidUsageError, 'coverage_modes requires at least one mode (e.g. [:lines])' if modes_array.empty?

      unknown = modes_array - COVERAGE_MODES
      unless unknown.empty?
        raise InvalidUsageError,
              "unknown coverage modes: #{unknown.inspect}; allowed: #{COVERAGE_MODES.inspect}"
      end

      @coverage_modes = modes_array.uniq.freeze
    end

    # Hash form of {#coverage_modes} for splatting into
    # `Coverage.start`. `[:lines, :branches]` becomes
    # `{lines: true, branches: true}`.
    def coverage_modes_for_start
      coverage_modes.to_h { |m| [m, true] }.freeze
    end

    # Internal method on the tracer pipeline.
    # @api private
    def read_coverage_modes
      return @coverage_modes if defined?(@coverage_modes) && @coverage_modes

      DEFAULT_COVERAGE_MODES
    end
    private :read_coverage_modes

    # Internal method on the tracer pipeline.
    # @api private
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

    # Reporter DSL. Accumulates each call onto an internal list of
    # `[name_or_class, opts]` pairs that `Reporters::Registry` walks
    # at finalize-time. Matches the `track_files` accumulator shape.
    #
    # Shapes:
    #   add_reporter :terminal
    #   add_reporter :json
    #   add_reporter MyCustomReporter, color: false
    #
    # Symbol names must match `Reporters::Registry::BUILT_INS.keys`
    # (`:terminal`, `:json`, `:html`). Class values are
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

    # Internal method on the tracer pipeline.
    # @api private
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

    # Internal method on the tracer pipeline.
    # @api private
    def reporter_builtins_keys
      return [] unless defined?(RSpecTracer::Reporters::Registry)

      RSpecTracer::Reporters::Registry::BUILT_INS.keys
    end

    # Add a filter to exclude files from the tracer's per-example
    # dependency graph. Files matching the filter are not registered
    # as deps, so changes to them don't trigger re-runs.
    #
    # The filter applies uniformly to both fresh per-example
    # attributions AND prior-snapshot carry-forward (warm-run path).
    # Adding a filter between runs immediately drops matching paths
    # from the next warm run's `@all_files` and dependency graph;
    # no cold run is required.
    #
    # The default filter list (loaded by `lib/rspec_tracer/load_default_config.rb`
    # before the user's `.rspec-tracer` runs) excludes Ruby toolchain
    # paths (`/vendor/bundle/`, `/usr/local/bundle/`, rbenv / asdf / rvm)
    # AND rspec-tracer's own output dirs (`/rspec_tracer_cache/`,
    # `/rspec_tracer_coverage/`, `/rspec_tracer_report/`,
    # `rspec_tracer.lock`). Use `filters.clear` in `.rspec-tracer`
    # before adding your own if you need to start from a blank list,
    # but be aware you'll then need to re-add the toolchain + tracer-
    # output exclusions yourself.
    #
    # @param filter [String, Regexp, Array, RSpecTracer::Filter, nil]
    #   filter spec. Nil + a block also accepted; the block receives
    #   a `source_file` Hash (`:name` / `:file_path`) and returns
    #   true to exclude.
    # @return [Array] the updated filters list.
    # @example String match (substring)
    #   add_filter '/vendor/bundle/'
    # @example Regex match
    #   add_filter %r{^/helpers/}
    # @example Block
    #   add_filter { |source_file| source_file[:file_path].include?('/helpers/') }
    # @example Array of mixed types
    #   add_filter ['/helpers/', %r{^/utils/}]
    def add_filter(filter = nil, &)
      filters << parse_filter(filter, &)
    end

    # @return [Array] the currently-registered dep-graph filters.
    #   Use `filters.clear` to reset.
    def filters
      @filters ||= []
    end

    # Bulk filters assignment is intentionally rejected — use
    # {#filters} `.clear` + repeated {#add_filter} instead so each
    # entry routes through the same parser.
    #
    # @raise [NotImplementedError]
    def filters=(new_filteres)
      raise NotImplementedError
    end

    # Add a filter to exclude files from coverage reporting (NOT
    # from the tracer's dep graph). Use {#add_filter} for the
    # dep graph; this controls SimpleCov-style coverage output only.
    #
    # @param filter [String, Regexp, Array, nil] same shape as
    #   {#add_filter}'s filter arg.
    # @return [Array]
    # @example
    #   add_coverage_filter %w[/spec/ /test/ /vendor/bundle/]
    def add_coverage_filter(filter = nil, &)
      coverage_filters << parse_filter(filter, &)
    end

    # @return [Array] the currently-registered coverage filters.
    #   Use `coverage_filters.clear` to reset.
    def coverage_filters
      @coverage_filters ||= []
    end

    # Bulk coverage_filters assignment intentionally rejected — see
    # {#filters=}.
    #
    # @raise [NotImplementedError]
    def coverage_filters=(new_filteres)
      raise NotImplementedError
    end

    # Internal method on the tracer pipeline.
    # @api private
    def valid_s3_path?(s3_path)
      uri = URI.parse(s3_path)

      uri.scheme == 's3' && !uri.host.empty?
    rescue URI::InvalidURIError => _e
      false
    end

    # Internal method on the tracer pipeline.
    # @api private
    def parallel_tests_id
      if ParallelTests.first_process?
        'parallel_tests_1'
      else
        "parallel_tests_#{ENV.fetch('TEST_ENV_NUMBER', nil)}"
      end
    end

    # Internal method on the tracer pipeline.
    # @api private
    def parse_filter(filter = nil, &block)
      arg = filter || block

      raise ArgumentError, 'Either a filter or a block required' if arg.nil?

      RSpecTracer::Filter.register(arg)
    end

    public

    # Catches typos in `.rspec-tracer` config files. When the user
    # mistypes a DSL name (e.g. `track_files_glob` for `track_files`),
    # bare `NoMethodError` puts a Ruby backtrace in their face. This
    # surface raises `InvalidUsageError` with a stdlib `DidYouMean`
    # suggestion when the typo is close to a known DSL method;
    # otherwise it falls through to NoMethodError so internal
    # respond_to? probes / non-DSL undefined-method usage retains
    # standard Ruby semantics.
    def method_missing(name, *args, **kwargs, &)
      return super if name.to_s.end_with?('=')

      candidates = RSpecTracer::Configuration::DslTypoSuggester.candidates
      suggestion = candidates.empty? ? nil : RSpecTracer::Configuration::DslTypoSuggester.nearest(name.to_s, candidates)
      return super if suggestion.nil?

      raise InvalidUsageError,
            "unknown .rspec-tracer DSL method #{name.inspect}; did you mean #{suggestion.inspect}?"
    end

    # Internal method on the tracer pipeline.
    # @api private
    def respond_to_missing?(name, include_private = false)
      super
    end

    # Helpers for the DSL-typo `did you mean` surface. Lives in a
    # dedicated module so its methods stay outside the configure-time
    # `alias_method :"_#{name}"` wrapper loop in `Configuration#configure`
    # (which iterates Configuration's `private_instance_methods(false)`
    # twice during `load_default_config` + `load_local_config` and would
    # double-alias any helper instance methods we kept here).
    module DslTypoSuggester
      # Internal helper for the tracer pipeline.
      # @api private
      def self.candidates
        # Strip one or more leading `_` to canonicalize through the
        # configure wrapper's aliasing levels (single underscore after
        # one configure, double after two, etc.).
        RSpecTracer.private_methods(true).each_with_object([]) do |m, acc|
          s = m.to_s
          next unless s.start_with?('_')
          next if s.end_with?('=')

          acc << s.sub(/\A_+/, '')
        end.uniq
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.nearest(typed, candidates)
        prefix_match = candidates
          .select { |c| typed.start_with?(c) || c.start_with?(typed) }
          .max_by(&:length)
        return prefix_match if prefix_match

        require 'did_you_mean'
        ::DidYouMean::SpellChecker.new(dictionary: candidates).correct(typed).first
      rescue LoadError
        nil
      end
    end
  end
  # rubocop:enable Metrics/ModuleLength
end
