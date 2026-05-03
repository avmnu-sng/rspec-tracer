# frozen_string_literal: true

require 'coverage'
require 'digest'
require 'json'
require 'set'

require_relative 'tracker/coverage_adapter'
require_relative 'tracker/declared_globs'
require_relative 'tracker/dependency_graph'
require_relative 'tracker/env_matcher'
require_relative 'tracker/env_snapshot'
require_relative 'tracker/example_registry'
require_relative 'tracker/file_digest'
require_relative 'tracker/filter'
require_relative 'tracker/input'
require_relative 'tracker/io_hooks'
require_relative 'tracker/loaded_files_tracker'
require_relative 'tracker/new_file_detector'
require_relative 'tracker/whole_suite_invalidators'
require_relative 'storage/json_backend'
require_relative 'storage/schema'
require_relative 'storage/snapshot'
require_relative 'storage/sqlite_backend'

module RSpecTracer
  # Top-level coordinator for the v2 core engine. Wires
  # CoverageAdapter + IOHooks + DeclaredGlobs + NewFileDetector +
  # WholeSuiteInvalidators + LoadedFilesTracker + ExampleRegistry +
  # DependencyGraph + Storage into a single pipeline.
  #
  # Named `Engine` rather than `Tracker` because the `Tracker`
  # namespace is already taken by the sub-module that houses the
  # leaf observers (`Tracker::CoverageAdapter`, `Tracker::IOHooks`,
  # etc.). `RSpecTracer.engine` is the public accessor the RSpec
  # hooks dispatch through during a run.
  #
  # Lifecycle (driven by RSpec hooks in `lib/rspec_tracer.rb`):
  #
  #   engine = Engine.new(configuration: RSpecTracer)
  #   engine.setup                       # install hooks, load cache,
  #                                      # compute filter decisions
  #   engine.run_example?(id)            # per-example filter (from cache)
  #   engine.register_example(example)   # record metadata + duplicates
  #   engine.example_started             # peek baseline + open bucket
  #     # ... example body runs, IOHooks record into bucket ...
  #   engine.example_finished(id)        # diff coverage, attribute, close
  #   engine.on_example_{passed,failed,pending,skipped}(id, result)
  #   engine.finalize                    # persist snapshot + coverage
  #
  # Per-example coverage delta map: peek baseline at example_started,
  # peek again at example_finished, store the per-line strength delta
  # under `@examples_coverage[id][file_path][line]`. Reporters::
  # CoverageJsonReporter consumes the cumulative coverage at finalize
  # via Tracker::CoverageAdapter#peek_unfiltered + the engine's
  # `merge_skipped_coverage` algorithm.
  #
  # Cache parity: `finalize` builds a Snapshot with file-name-keyed
  # dependency / reverse_dependency / all_files maps (matching the
  # 1.x on-disk convention - root-stripped file names with a leading
  # "/") and hands it to Storage::JsonBackend. The schema bump to 3
  # from M3.7 adds `boot_set`; everything else mirrors the 1.x
  # cache layout byte-for-byte.
  # rubocop:disable Metrics/ClassLength
  class Engine
    EXAMPLE_RUN_REASON = {
      explicit_run: 'Explicit run',
      no_cache: 'No cache',
      interrupted: 'Interrupted previously',
      flaky_example: 'Flaky example',
      failed_example: 'Failed previously',
      pending_example: 'Pending previously',
      files_changed: 'Files changed',
      whole_suite_invalidator: 'Whole-suite invalidator changed',
      env_changed: 'Environment changed'
    }.freeze

    # Map from Filter#select reasons to the legacy-shaped strings
    # users see in test output ("foo (Files changed)"). Keeps the
    # user surface unchanged under v2.
    FILTER_REASON_STRINGS = {
      whole_suite_invalidator: EXAMPLE_RUN_REASON[:whole_suite_invalidator],
      interrupted: EXAMPLE_RUN_REASON[:interrupted],
      flaky_example: EXAMPLE_RUN_REASON[:flaky_example],
      failed_example: EXAMPLE_RUN_REASON[:failed_example],
      pending_example: EXAMPLE_RUN_REASON[:pending_example],
      no_cache: EXAMPLE_RUN_REASON[:no_cache],
      files_changed: EXAMPLE_RUN_REASON[:files_changed],
      env_changed: EXAMPLE_RUN_REASON[:env_changed]
    }.freeze

    attr_reader :registry, :graph, :loaded_files_tracker, :coverage_adapter,
                :declared_globs, :whole_suite_invalidators, :new_file_detector,
                :env_snapshot, :storage_backend, :all_examples, :duplicate_examples,
                :examples_coverage, :all_files

    def initialize(configuration: RSpecTracer)
      @configuration = configuration
      @filtered_examples = {}
      @all_examples = {}
      @duplicate_examples = {}
      @examples_coverage = {}
      @all_files = {}
      @tracks_files = Hash.new { |h, id| h[id] = Set.new } # id => Set<abs_path>
      @tracks_env = Hash.new { |h, id| h[id] = Set.new }   # id => Set<env_name>
      @tracked_env_names = Set.new
      @config_tracked_env_names = Set.new # M5.3 config-level subset (post-expansion)
      @previous_snapshot = nil
      @run_id = nil
      @before_peek = nil
    end

    def setup
      @configuration.freeze_declared_globs!

      build_observers
      install_io_hooks
      install_rails_observers
      ensure_coverage_started

      @loaded_files_tracker.capture_boot_set!
      @declared_globs.walk

      @previous_snapshot = load_previous_snapshot
      seed_state_from_previous(@previous_snapshot) if @previous_snapshot
      register_config_tracked_env_names
      compute_filter_decisions
      self
    end

    # --- filter-phase surface (mirrors legacy Runner) --------------

    def run_example?(example_id)
      return true if @configuration.run_all_examples

      previously_seen = @previous_snapshot&.all_examples&.key?(example_id)
      !previously_seen || @filtered_examples.key?(example_id)
    end

    def run_example_reason(example_id)
      return EXAMPLE_RUN_REASON[:explicit_run] if @configuration.run_all_examples

      @filtered_examples[example_id] || EXAMPLE_RUN_REASON[:no_cache]
    end

    def register_example(example)
      example_id = example[:example_id]
      @registry.register(example_id, metadata: example, identity_hash: example_id)
      @all_examples[example_id] ||= example
      @duplicate_examples[example_id] ||= []
      @duplicate_examples[example_id] << example
      self
    end

    # M5.2 per-example tracking DSL hook. Called from RunnerHook with
    # the normalized `{files: Set<String>, env: Set<String>}` that
    # `RSpec::Metadata.tracks_for(example)` produced. Resolves the
    # file globs against the project root once per distinct glob
    # string (memoized) and unions the matching Inputs into this
    # example's dependency set. Env names are accumulated into
    # `@tracked_env_names` so the finalize snapshot covers every key
    # the run cared about.
    #
    # M5.3: per-example env entries may carry wildcard patterns
    # (`tracks: { env: 'RAILS_*' }`). `EnvMatcher.expand` is the
    # single funnel - literals pass through, wildcards expand against
    # the live ENV, and unsupported syntax raises ArgumentError at
    # this point (RunnerHook Pass 1, before any example body runs).
    # rubocop:disable Metrics/PerceivedComplexity
    def register_tracks(example_id, tracks)
      files = tracks[:files] || tracks['files'] || Set.new
      envs = tracks[:env] || tracks['env'] || Set.new

      files.each { |glob| @tracks_files[example_id].merge(resolved_glob_inputs(glob)) } unless files.empty?
      return self if envs.empty?

      expanded = RSpecTracer::Tracker::EnvMatcher.expand(envs.map(&:to_s))
      @tracks_env[example_id].merge(expanded)
      @tracked_env_names.merge(expanded)
      self
    end
    # rubocop:enable Metrics/PerceivedComplexity

    # M5.2 / M5.3. Called from RunnerHook AFTER the filter-decision
    # pre-walk has populated `@tracks_env` / `@tracked_env_names` for
    # every example. Compares each declared env key against the
    # previous snapshot's `env_snapshot` via Tracker::EnvSnapshot;
    # marks any example whose tracked-env set intersects the
    # invalidated set as re-runnable. Strictly additive vs other
    # filter reasons - if the example was already in
    # `@filtered_examples` for a stronger reason (files_changed /
    # whole_suite_invalidator / failed_example / ...), env_changed
    # does NOT overwrite.
    #
    # M5.3 config-level path: when an invalidated key intersects
    # `@config_tracked_env_names` (the post-expansion config-level
    # set), every previously-seen example re-runs - mirrors the
    # `track_files` "declared globs attach to every example"
    # semantics. New examples (not in @previous_snapshot.all_examples)
    # already run via the no_cache path; no special-casing needed.
    def apply_env_filter_decisions
      return self if @previous_snapshot.nil?
      return self if @tracked_env_names.empty?

      invalidated = @env_snapshot.invalidated_keys(
        @previous_snapshot.env_snapshot, @tracked_env_names
      )
      return self if invalidated.empty?

      reason = FILTER_REASON_STRINGS.fetch(:env_changed)
      mark_all_prev_examples(reason) if invalidated.intersect?(@config_tracked_env_names)
      mark_per_example_intersections(invalidated, reason)
      self
    end

    def deregister_duplicate_examples
      @duplicate_examples.select! { |_, entries| entries.count > 1 }
      return if @duplicate_examples.empty?

      @all_examples.reject! { |id, _| @duplicate_examples.key?(id) }
      self
    end

    # --- per-example surface --------------------------------------

    def example_started
      @before_peek = @coverage_adapter.peek
      @current_bucket = {}
      @current_rails_bucket = {}
      RSpecTracer::Tracker::IOHooks.set_bucket(@current_bucket)
      set_rails_bucket(@current_rails_bucket)
      self
    end

    def example_finished(example_id)
      after_peek = @coverage_adapter.peek
      record_coverage_delta(example_id, @before_peek, after_peek)
      io_inputs = @current_bucket.values
      rails_inputs = @current_rails_bucket ? @current_rails_bucket.values : []
      RSpecTracer::Tracker::IOHooks.clear_bucket
      clear_rails_bucket

      transitive_inputs = @loaded_files_tracker.loaded_set_inputs |
        @loaded_files_tracker.stop_example(example_id)
      coverage_inputs = @coverage_adapter.compute_diff(@before_peek, after_peek)
      declared_inputs = @declared_globs.walk
      tracks_inputs = per_example_tracks_inputs(example_id)
      attribute_to_example(
        example_id,
        coverage_inputs | transitive_inputs | io_inputs.to_set |
          rails_inputs.to_set | declared_inputs | tracks_inputs
      )

      @before_peek = nil
      @current_bucket = nil
      @current_rails_bucket = nil
      self
    end

    def on_example_skipped(example_id)
      @registry.register(example_id) unless @registry.registered?(example_id)
      @registry.update_status(example_id, :skipped)
      self
    end

    def on_example_passed(example_id, result)
      return if @duplicate_examples[example_id]&.count.to_i > 1

      @registry.update_status(example_id, :passed)
      record_execution_result(example_id, result)
      self
    end

    def on_example_failed(example_id, result)
      return if @duplicate_examples[example_id]&.count.to_i > 1

      @registry.update_status(example_id, :failed)
      record_execution_result(example_id, result)
      self
    end

    def on_example_pending(example_id, result)
      return if @duplicate_examples[example_id]&.count.to_i > 1

      @registry.update_status(example_id, :pending)
      record_execution_result(example_id, result)
      self
    end

    # --- finalize ------------------------------------------------

    def finalize
      @registry.all_example_ids.each do |id|
        next if @registry.status_of(id)

        @registry.update_status(id, :interrupted)
      end

      snapshot = build_snapshot
      @storage_backend.save_graph(snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      uninstall_rails_observers
      snapshot
    end

    # For every previously-skipped example id, accumulate per-line
    # coverage strengths from the previous run's per-example coverage
    # map into the missed_coverage return value. Deleted files /
    # missing entries are skipped silently. Consumed by
    # Reporters::CoverageJsonReporter at finalize time so coverage.json
    # carries forward the contribution of skipped examples.
    #
    # Returns Hash[file_path => Hash[line_number => cumulative_strength]].
    def merge_skipped_coverage(skipped_ids, previous_examples_coverage = nil)
      source = previous_examples_coverage || @previous_snapshot&.examples_coverage || {}
      missed = Hash.new { |h, f| h[f] = Hash.new(0) }

      skipped_ids.each do |example_id|
        example_coverage = source[example_id]
        next if example_coverage.nil?

        example_coverage.each do |file_path, line_coverage|
          accumulate_line_coverage(missed[file_path], line_coverage)
        end
      end

      missed
    end

    # --- accessors used by specs ---------------------------------

    def filtered_example_ids
      @filtered_examples.keys
    end

    def previous_snapshot_loaded?
      !@previous_snapshot.nil?
    end

    private

    # M5.3. Read the config-level `track_env(*names)` accumulator,
    # expand any wildcard patterns against the live ENV via
    # EnvMatcher.expand (which raises ArgumentError on unsupported
    # syntax - intentionally surfaces config errors at run start),
    # and seed both `@config_tracked_env_names` (for the global
    # mark-every-example branch in apply_env_filter_decisions) and
    # `@tracked_env_names` (so the finalize snapshot includes every
    # config-level key alongside per-example keys).
    def register_config_tracked_env_names
      patterns = @configuration.tracked_env_names
      return if patterns.nil? || patterns.empty?

      expanded = RSpecTracer::Tracker::EnvMatcher.expand(patterns)
      @config_tracked_env_names.merge(expanded)
      @tracked_env_names.merge(expanded)
    end

    # M5.3. Mark every previously-seen example for re-run. Called
    # when a config-level env key flips between runs.
    def mark_all_prev_examples(reason)
      @previous_snapshot.all_examples.each_key do |example_id|
        next if @filtered_examples.key?(example_id)

        @filtered_examples[example_id] = reason
      end
    end

    # M5.2 / M5.3 per-example env-changed mark. Walks @tracks_env,
    # marks examples whose declared env set intersects invalidated.
    # Additive vs other filter reasons (won't overwrite).
    def mark_per_example_intersections(invalidated, reason)
      @tracks_env.each do |example_id, envs|
        next unless envs.intersect?(invalidated)
        next if @filtered_examples.key?(example_id)

        @filtered_examples[example_id] = reason
      end
    end

    def build_observers
      @registry = RSpecTracer::Tracker::ExampleRegistry.new
      @graph = RSpecTracer::Tracker::DependencyGraph.new
      @coverage_adapter = RSpecTracer::Tracker::CoverageAdapter.new(
        root: @configuration.root, filters: @configuration.filters
      )
      @declared_globs = RSpecTracer::Tracker::DeclaredGlobs.new(
        root: @configuration.root, globs: @configuration.declared_globs
      )
      @whole_suite_invalidators = RSpecTracer::Tracker::WholeSuiteInvalidators.new(
        root: @configuration.root
      )
      @env_snapshot = RSpecTracer::Tracker::EnvSnapshot.new
      @new_file_detector = RSpecTracer::Tracker::NewFileDetector.new(
        root: @configuration.root, declared_globs: @configuration.declared_globs
      )
      @loaded_files_tracker = RSpecTracer::Tracker::LoadedFilesTracker.new(
        root: @configuration.root, enabled: @configuration.transitive_load_tracking
      )
      @storage_backend = build_storage_backend(@configuration.cache_path)
    end

    # Resolve the configured storage backend to a concrete instance.
    # JsonBackend threads the retention / size-budget knobs and the
    # serializer opt; SqliteBackend ignores them (single-file,
    # latest-run only). A missing sqlite3 gem or JRuby / MRI < 3.2
    # host raises SqliteBackendError; we warn and fall back to the
    # default :json backend so the user's suite still runs - same
    # graceful-degradation contract as the remote cache backends.
    def build_storage_backend(cache_path)
      case @configuration.storage_backend
      when :sqlite
        build_sqlite_backend(cache_path)
      else
        build_json_backend(cache_path)
      end
    end

    def build_json_backend(cache_path)
      RSpecTracer::Storage::JsonBackend.new(
        cache_path: cache_path,
        logger: @configuration.logger,
        retention_local_count: @configuration.cache_retention_local_count,
        warn_per_file_mb: @configuration.cache_size_warn_per_file_mb,
        warn_total_mb: @configuration.cache_size_warn_total_mb,
        serializer: @configuration.storage_backend_opts[:serializer] || :json
      )
    end

    def build_sqlite_backend(cache_path)
      RSpecTracer::Storage::SqliteBackend.new(
        cache_path: cache_path, logger: @configuration.logger
      )
    rescue RSpecTracer::Storage::SqliteBackend::SqliteBackendError => e
      @configuration.logger.warn(
        "rspec-tracer: sqlite backend unavailable (#{e.message}); falling back to :json"
      )
      build_json_backend(cache_path)
    end

    def install_io_hooks
      declared = @declared_globs
      RSpecTracer::Tracker::IOHooks.install(
        root: @configuration.root,
        filter: ->(path) { !declared.covers?(path) }
      )
    end

    # Install the Rails-observer family (ActionView notifications +
    # I18n backend prepend) when Rails is detected in the process.
    # Runs at setup time so the subscribers are attached before the
    # first example fires. Errors here never propagate - the tracer
    # gracefully degrades to IOHooks-only behavior.
    def install_rails_observers
      return unless @configuration.rails?

      require_relative 'rails/notifications'
      require_relative 'rails/i18n_tracking'

      declared = @declared_globs
      filter = ->(path) { !declared.covers?(path) }
      ar_paths = ar_schema_notifications_enabled? ? ar_schema_path_probes : []

      RSpecTracer::Rails::Notifications.install(
        root: @configuration.root, filter: filter, ar_schema_paths: ar_paths
      )
      RSpecTracer::Rails::I18nTracking.install(
        root: @configuration.root, filter: filter
      )

      arm_ar_schema_setup_warn if ar_schema_notifications_enabled?

      @rails_observers_installed = true
    rescue StandardError => e
      @configuration.logger.warn(
        "rspec-tracer: Rails observer install failed (#{e.class}: #{e.message})"
      )
      @rails_observers_installed = false
    end

    # `track_ar_schema_notifications` promises per-example attribution
    # of `db/schema.rb` via the `sql.active_record` subscriber. That
    # narrow promise only holds when no per-example AR cleanup
    # mechanism fires queries inside the rspec-tracer per-example
    # bucket window. Common Rails setups trip this:
    #
    #   - `use_transactional_fixtures = true` (Rails default): per-
    #     example BEGIN/COMMIT fires sql.active_record -> every
    #     example gets schema attributed -> any schema mutation re-
    #     runs every example (safe but wide).
    #   - DatabaseCleaner :truncation / :deletion / :transaction in
    #     around hooks: same outcome.
    #
    # Defer the check to before(:suite): at engine.setup the user has
    # not run their RSpec.configure block yet, so
    # `use_transactional_fixtures` is unset.
    def arm_ar_schema_setup_warn
      return unless defined?(::RSpec) && ::RSpec.respond_to?(:configure)

      logger = @configuration.logger
      ::RSpec.configure do |config|
        config.before(:suite) do
          next unless ::RSpec.configuration.respond_to?(:use_transactional_fixtures)
          next if ::RSpec.configuration.use_transactional_fixtures == false

          logger.warn(
            'rspec-tracer: track_ar_schema_notifications is enabled but ' \
            'use_transactional_fixtures defaults to true; per-example ' \
            'BEGIN/COMMIT fires sql.active_record so db/schema.rb gets ' \
            'attributed to every AR-touching example (safe, but widens ' \
            'invalidation). For narrow attribution, set ' \
            'use_transactional_fixtures = false and use sequence-based ' \
            'factories (or another non-AR cleanup mechanism). See ' \
            'README section "Narrow AR-schema attribution".'
          )
        end
      end
    rescue StandardError => e
      @configuration.logger.warn(
        "rspec-tracer: ar-schema warn install failed (#{e.class}: #{e.message})"
      )
    end

    def uninstall_rails_observers
      return unless rails_observers_installed?

      RSpecTracer::Rails::Notifications.uninstall
      RSpecTracer::Rails::I18nTracking.uninstall
      @rails_observers_installed = false
    rescue StandardError
      @rails_observers_installed = false
    end

    def rails_observers_installed?
      defined?(@rails_observers_installed) && @rails_observers_installed == true
    end

    # rubocop:disable Naming/AccessorMethodName
    def set_rails_bucket(bucket)
      return unless rails_observers_installed?

      RSpecTracer::Rails::Notifications.set_bucket(bucket)
    end
    # rubocop:enable Naming/AccessorMethodName

    def clear_rails_bucket
      return unless rails_observers_installed?

      RSpecTracer::Rails::Notifications.clear_bucket
    end

    def ar_schema_notifications_enabled?
      return false unless @configuration.respond_to?(:track_ar_schema_notifications?)

      @configuration.track_ar_schema_notifications?
    end

    def ar_schema_path_probes
      %w[db/schema.rb db/structure.sql].each_with_object([]) do |rel, acc|
        abs = File.expand_path(rel, @configuration.root)
        acc << abs if File.file?(abs)
      end
    end

    # Delegate to the legacy ::Coverage bootstrap if SimpleCov isn't
    # already running. Matches RSpecTracer.setup_coverage behavior so
    # v2 and legacy agree on when to call ::Coverage.start.
    def ensure_coverage_started
      return if defined?(SimpleCov) && SimpleCov.running
      return if ::Coverage.respond_to?(:running?) && ::Coverage.running?

      ::Coverage.start
    rescue RuntimeError
      # ::Coverage.start raises if already started on some Rubies
      # without a running? predicate; safe to ignore.
      nil
    end

    # Under parallel_tests, each worker writes to its own per-worker
    # cache dir (`rspec_tracer_cache/parallel_tests_N/`) but warm-run
    # reads come from the MERGED top-level cache (`rspec_tracer_cache/`,
    # one level up). Last-process finalize at exit purges the per-worker
    # dirs, so only the merged snapshot survives between runs. Match
    # 1.x Cache#load_cache_for_run's `File.dirname(cache_path) if
    # parallel_tests?` behavior so warm runs under parallel_tests
    # actually skip examples.
    def load_previous_snapshot
      read_backend = build_read_backend
      read_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)
    end

    def build_read_backend
      return @storage_backend unless RSpecTracer.parallel_tests?

      parent_cache_path = File.dirname(@configuration.cache_path)
      build_storage_backend(parent_cache_path)
    end

    # On warm runs, skipped examples don't re-populate @all_examples,
    # @all_files, or @graph - only newly-run examples do. Without
    # seeding, the next save would drop the skipped examples'
    # metadata + deps, and the following warm run would see them as
    # "not previously seen" and force a cold re-run of the entire
    # suite. Seed the three state buckets from the previous snapshot
    # so newly-run examples overwrite and skipped examples carry
    # forward.
    #
    # examples_coverage is NOT seeded here. A populated cache can
    # carry a large examples_coverage map; eagerly materializing it
    # at setup defeats LazySnapshot's whole point for the SQLite
    # backend. The merge happens at build_snapshot time via
    # merge_examples_coverage_with_previous instead.
    def seed_state_from_previous(prev)
      seed_all_examples_from_previous(prev)
      seed_all_files_from_previous(prev)
      seed_graph_from_previous(prev)
    end

    def seed_all_examples_from_previous(prev)
      return unless prev.all_examples.is_a?(Hash)

      prev.all_examples.each do |id, meta|
        @all_examples[id] = meta
      end
    end

    # prev.all_files is file-name-keyed; the engine's @all_files is
    # abs-path-keyed (path_to_file_name round-trips via the root prefix).
    #
    # Re-applies the current filter list at seed time so users who
    # add a filter mid-development see the carried-over file entries
    # drop on the next run (instead of waiting for a cold run). The
    # filter contract should hold for both fresh attributions
    # (attribute_to_example) and prior-snapshot carry-forward —
    # otherwise add_filter has split semantics and a freshly-added
    # filter does not exclude already-cached paths.
    def seed_all_files_from_previous(prev)
      return unless prev.all_files.is_a?(Hash)

      prev.all_files.each_value do |meta|
        next unless meta.is_a?(Hash)

        file_path = symbol_or_string(meta, :file_path)
        next if file_path.nil?

        file_name = symbol_or_string(meta, :file_name) || path_to_file_name(file_path)
        next if filtered_by_current_filters?(file_name)

        @all_files[file_path] = {
          file_name: file_name,
          file_path: file_path,
          digest: symbol_or_string(meta, :digest)
        }
      end
    end

    # prev.dependency keys on example_id, values are Set<file_name>.
    # Register in @graph via absolute paths so the on-disk shape
    # (file_name) converts at save time via dependency_by_name.
    #
    # Drops paths matching the current filter list so previously-
    # cached deps that the new filter excludes do not leak through
    # the carry-forward seed path. Same rationale as
    # seed_all_files_from_previous: the filter contract is one
    # contract, applied uniformly across fresh + carry-forward
    # attributions.
    def seed_graph_from_previous(prev)
      return unless prev.dependency.is_a?(Hash)

      prev.dependency.each do |example_id, file_names|
        paths = Set.new
        file_names.each do |name|
          next if filtered_by_current_filters?(name)

          paths << absolute_path(name)
        end
        @graph.register_example(example_id, paths)
      end
    end

    # Helper: returns true if the file name matches any currently-
    # configured filter. Mirrors the check site at
    # `attribute_to_example` (engine.rb:770) so both fresh + carry-
    # forward attributions converge on the same filter behavior.
    def filtered_by_current_filters?(file_name)
      @configuration.filters.any? { |f| f.match?(file_name: file_name) }
    end

    def compute_filter_decisions
      prev = @previous_snapshot
      return if prev.nil?

      seed_registry_from_previous(prev)
      change_set = compute_change_set(prev)
      whole_suite = whole_suite_changed?(prev)

      result = RSpecTracer::Tracker::Filter.select(
        graph: graph_from_previous(prev),
        change_set: change_set,
        registry: @registry,
        whole_suite_invalidated: whole_suite,
        all_example_ids: prev.all_examples.keys.to_set
      )
      @filtered_examples = result.transform_values { |reason| FILTER_REASON_STRINGS.fetch(reason) }
    end

    SEED_STATUS_ORDER = %i[interrupted flaky failed pending].freeze
    private_constant :SEED_STATUS_ORDER

    def seed_registry_from_previous(prev)
      SEED_STATUS_ORDER.each do |status|
        ids = prev.send(:"#{status}_examples")
        ids.each { |id| seed_registry_entry(id, status, prev.all_examples[id] || {}) }
      end
    end

    def seed_registry_entry(id, status, metadata)
      return if @registry.registered?(id)

      @registry.register(id, metadata: metadata)
      @registry.update_status(id, status)
    end

    # Rebuild a DependencyGraph from the previous Snapshot so Filter
    # can intersect its cached dependency sets with the change_set.
    def graph_from_previous(prev)
      graph = RSpecTracer::Tracker::DependencyGraph.new
      prev.dependency.each { |id, paths| graph.register_example(id, paths) }
      graph
    end

    def compute_change_set(prev)
      changed = Set.new
      prev.all_files.each_value do |file_meta|
        file_name = symbol_or_string(file_meta, :file_name)
        cached_digest = symbol_or_string(file_meta, :digest)
        next if file_name.nil? || cached_digest.nil?

        current_digest = current_file_digest(file_name)
        changed << file_name if current_digest.nil? || current_digest != cached_digest
      end

      new_files = @new_file_detector.new_files(
        known_paths: prev.all_files.keys.to_set.to_set { |k| absolute_path(k) }
      )
      new_files.each { |input| changed << path_to_file_name(input.path) }
      changed
    end

    def whole_suite_changed?(prev)
      wsi_prev = prev.wsi_snapshot if prev.respond_to?(:wsi_snapshot)
      @whole_suite_invalidators.invalidated?(wsi_prev) ||
        @loaded_files_tracker.boot_set_invalidated?(prev.boot_set)
    end

    def current_file_digest(file_name)
      RSpecTracer::Tracker::FileDigest.compute(absolute_path(file_name))
    end

    def record_coverage_delta(example_id, before, after)
      entry = @examples_coverage[example_id] ||= {}

      (before.keys | after.keys).each do |path|
        b_lines = before[path]
        a_lines = after[path]
        next if b_lines == a_lines

        file_entry = entry[path] ||= {}
        accumulate_delta(file_entry, b_lines, a_lines)
      end
    end

    def accumulate_delta(file_entry, before_lines, after_lines)
      length = (after_lines || before_lines || []).length
      length.times do |i|
        delta = line_delta(before_lines && before_lines[i], after_lines && after_lines[i])
        file_entry[i] = delta if delta
      end
    end

    # Returns the positive coverage delta for one line, or nil if the
    # line isn't a delta worth recording (non-executable, identical,
    # or a stale-going-backward entry).
    def line_delta(before, after)
      return nil if after.nil? || before == after

      delta = after - (before || 0)
      delta.positive? ? delta : nil
    end

    def accumulate_line_coverage(accumulator, line_coverage)
      line_coverage.each do |line_key, strength|
        index = line_key.to_i
        accumulator[index] += strength || 0
      end
    end

    def attribute_to_example(example_id, inputs)
      paths = Set.new
      inputs.each do |input|
        next if @configuration.filters.any? { |f| f.match?(file_name: path_to_file_name(input.path)) }

        paths << input.path
        @all_files[input.path] = {
          file_name: path_to_file_name(input.path),
          file_path: input.path,
          digest: input.digest
        }
      end
      @graph.register_example(example_id, paths)
    end

    def record_execution_result(example_id, result)
      return unless @all_examples.key?(example_id)

      @all_examples[example_id][:execution_result] = formatted_execution_result(result)
    end

    def formatted_execution_result(result)
      {
        started_at: result.started_at.utc,
        finished_at: result.finished_at.utc,
        run_time: result.run_time,
        status: result.status.to_s
      }
    end

    def build_snapshot
      run_id = Digest::MD5.hexdigest(@all_examples.keys.sort.to_json)
      @run_id = run_id

      RSpecTracer::Storage::Snapshot.new(
        schema_version: RSpecTracer::Storage::Schema::CURRENT,
        run_id: run_id,
        all_examples: @all_examples,
        duplicate_examples: duplicates_for_snapshot,
        interrupted_examples: @registry.ids_with_status(:interrupted),
        flaky_examples: @registry.ids_with_status(:flaky),
        failed_examples: @registry.ids_with_status(:failed),
        pending_examples: @registry.ids_with_status(:pending),
        skipped_examples: @registry.ids_with_status(:skipped),
        all_files: all_files_by_name,
        dependency: dependency_by_name,
        reverse_dependency: reverse_dependency_by_name,
        examples_coverage: merge_examples_coverage_with_previous,
        boot_set: @loaded_files_tracker.boot_set_digest_snapshot,
        wsi_snapshot: @whole_suite_invalidators.digest_snapshot,
        env_snapshot: env_snapshot_for_persistence,
        env_dependency: env_dependency_for_persistence,
        cache_hit_reason: @filtered_examples.values.tally
      )
    end

    # Merge the current run's per-example coverage with the previous
    # run's. Re-run examples contribute their freshly-computed map
    # (record_coverage_delta overwrote per-line strengths, so
    # @examples_coverage[id] is the authoritative new coverage).
    # Skipped examples don't appear in @examples_coverage, so the
    # prev map carries them forward unchanged. Previously in
    # seed_state_from_previous; moved here so large caches don't
    # pay the full examples_coverage materialization cost at setup
    # time. Preserves 1.x semantics: the saved map is the union of
    # (prev minus this-run's keys) + this-run's entries.
    def merge_examples_coverage_with_previous
      merged = {}
      if @previous_snapshot
        prev = @previous_snapshot.examples_coverage
        if prev.is_a?(Hash)
          prev.each { |id, cov| merged[id] = cov unless @examples_coverage.key?(id) }
        end
      end
      @examples_coverage.each { |id, cov| merged[id] = cov }
      merged
    end

    # Snapshot only the env keys THIS run tracked - persisting keys
    # that stopped being tracked (user removed `tracks: env: ...`
    # between runs) would pin stale digests in the cache. Missing
    # keys on the next load just trigger a one-time re-run for any
    # example that reintroduces them, which is the correct behavior.
    def env_snapshot_for_persistence
      return {} if @env_snapshot.nil? || @tracked_env_names.empty?

      @env_snapshot.digest_snapshot(@tracked_env_names)
    end

    # M6.1. Project the per-example `@tracks_env` map (Set<env_name>
    # per example_id) into a JSON-friendly Hash[id => sorted Array]
    # for persistence. Reporters consume this to render the env-
    # dependency view on the Examples Dependency report. Empty sets
    # drop out so the on-disk map stays narrow. Sort keeps the output
    # deterministic for downstream diffs and golden tests.
    def env_dependency_for_persistence
      result = {}
      @tracks_env.each do |example_id, names|
        next if names.nil? || names.empty?

        result[example_id] = names.to_a.sort
      end
      result
    end

    # Resolve one glob against the project root into a Set of
    # `:declared`-kind Inputs. Walks via Dir.glob
    # (FNM_PATHNAME+FNM_EXTGLOB like DeclaredGlobs so user muscle
    # memory works identically) and digests each hit with SHA256.
    # Unreadable files are skipped silently - graceful degradation.
    # Memoized per distinct glob string so N examples declaring the
    # same glob pay the filesystem walk cost exactly once.
    def resolved_glob_inputs(glob)
      @resolved_glob_cache ||= {}
      @resolved_glob_cache[glob] ||= walk_one_glob(glob)
    end

    def walk_one_glob(glob)
      inputs = Set.new
      root = @configuration.root
      Dir.glob(glob, File::FNM_PATHNAME | File::FNM_EXTGLOB, base: root).each do |rel|
        abs = File.expand_path(rel, root)
        next unless abs.start_with?("#{root}/") && File.file?(abs)

        digest = tracks_file_digest(abs)
        next if digest.nil?

        inputs << RSpecTracer::Tracker::Input.for_file(
          path: abs, kind: :declared, digest: digest, root: root
        )
      end
      inputs
    end

    def tracks_file_digest(path)
      RSpecTracer::Tracker::FileDigest.compute(path)
    end

    # Materialize the per-example tracks-file Input set. Returns an
    # empty Set when the example has no `tracks: files:` metadata,
    # keeping the downstream union cheap for the 99% case.
    def per_example_tracks_inputs(example_id)
      set = @tracks_files[example_id]
      set.nil? || set.empty? ? Set.new : set.dup
    end

    def duplicates_for_snapshot
      @duplicate_examples.select { |_, entries| entries.count > 1 }
    end

    def all_files_by_name
      @all_files.each_with_object({}) do |(_, meta), acc|
        acc[meta[:file_name]] = meta
      end
    end

    def dependency_by_name
      @graph.dependency_hash.transform_values do |paths|
        paths.to_set { |p| path_to_file_name(p) }
      end
    end

    def reverse_dependency_by_name
      @graph.reverse_dependency_hash.each_with_object({}) do |(path, ids), acc|
        acc[path_to_file_name(path)] = ids.to_set
      end
    end

    def absolute_path(file_name)
      File.expand_path(file_name.to_s.sub(%r{^/}, ''), @configuration.root)
    end

    def path_to_file_name(abs_path)
      root_prefix = "#{@configuration.root}/"
      return abs_path unless abs_path.start_with?(root_prefix)

      "/#{abs_path[root_prefix.length..]}"
    end

    def symbol_or_string(hash, key)
      return hash[key] if hash.key?(key)

      hash[key.to_s]
    end
  end
  # rubocop:enable Metrics/ClassLength
end
