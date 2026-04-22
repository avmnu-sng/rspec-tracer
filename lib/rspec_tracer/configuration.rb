# frozen_string_literal: true

require_relative 'filter'
require_relative 'logger'

module RSpecTracer
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
    # M3.8 adds :sqlite. Keep the list closed so typos raise early.
    STORAGE_BACKEND_NAMES = %i[json].freeze

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

    def reports_s3_path(s3_path = nil)
      return @reports_s3_path if defined?(@reports_s3_path) && s3_path.nil?

      path = if ENV.key?('RSPEC_TRACER_REPORTS_S3_PATH')
               ENV['RSPEC_TRACER_REPORTS_S3_PATH']
             else
               s3_path
             end

      @reports_s3_path = path if valid_s3_path?(path)
    end

    def use_local_aws(new_flag = nil)
      return @use_local_aws if defined?(@use_local_aws) && new_flag.nil?

      @use_local_aws = if ENV.key?('RSPEC_TRACER_USE_LOCAL_AWS')
                         ENV['RSPEC_TRACER_USE_LOCAL_AWS'] == 'true'
                       else
                         new_flag == true
                       end
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

    # Opt in to the v2 core-engine pipeline (the in-tree
    # Tracker + Storage + Filter stack). Default `false` keeps every
    # existing run on the legacy Runner + CoverageReporter path, so
    # users upgrading to 2.0.pre don't change behavior silently.
    #
    # Setting `true` activates the new engine for the RSpec process.
    # The flag is a temporary bridge - removed once the RSpec
    # integration rework lands and the legacy runner retires.
    # Honors `RSPEC_TRACER_USE_V2_TRACKER` for CI that needs to flip
    # the flag without editing `.rspec-tracer`.
    def use_v2_tracker(new_flag = nil)
      return @use_v2_tracker if defined?(@use_v2_tracker) && new_flag.nil?

      @use_v2_tracker = if ENV.key?('RSPEC_TRACER_USE_V2_TRACKER')
                          ENV['RSPEC_TRACER_USE_V2_TRACKER'] == 'true'
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

    # M3.4 storage backend selector. Symbol form
    # (`storage_backend :json`); ENV `RSPEC_TRACER_STORAGE` wins over
    # the DSL argument, matching the `cache_dir` / `coverage_dir`
    # precedence convention so CI can swap backends without editing
    # `.rspec-tracer`. Backend-specific options are intentionally not
    # accepted here - the `configure` DSL wrapper strips Ruby 3+
    # kwargs (it forwards `*args, &block` only), so any opts interface
    # has to wait for the wrapper upgrade. M3.8 (SQLite) reopens this.
    def storage_backend(name = nil)
      return @storage_backend_name if defined?(@storage_backend_name) && @storage_backend_name && name.nil?

      env = ENV.fetch('RSPEC_TRACER_STORAGE', nil)
      resolved = (env || name || DEFAULT_STORAGE_BACKEND).to_sym

      unless STORAGE_BACKEND_NAMES.include?(resolved)
        raise InvalidUsageError,
              "unknown storage backend: #{resolved.inspect}; allowed: #{STORAGE_BACKEND_NAMES.inspect}"
      end

      @storage_backend_name = resolved
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
end
