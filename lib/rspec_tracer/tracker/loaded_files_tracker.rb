# frozen_string_literal: true

require 'coverage'
require 'set'

require_relative 'file_digest'
require_relative 'input'

module RSpecTracer
  module Tracker
    # Observer #5 in the 2.0 tracker pipeline. Closes the constants-
    # lookup blind spot documented in KNOWN_ISSUES.md B10.
    #
    # The bug: when file A defines constants at load time and example E2
    # references them without triggering a re-require, E2's coverage
    # diff is empty for A. If A changes, the filter incorrectly skips
    # E2 on the next run.
    #
    # The fix: track every project file Ruby has ever loaded during the
    # process, and attribute them as transitive dependencies of every
    # example that runs afterward.
    #
    #   - `@boot_set`: frozen Set<String> captured at Tracker.setup.
    #     Files loaded before any example runs (spec_helper requires,
    #     gem boot code, constant autoloads). Changes to these are
    #     whole-suite invalidators - any modification re-runs every
    #     example.
    #   - `@loaded_set`: append-only Set<String>. Grows as examples run
    #     and Coverage observes new files. Before each example, the
    #     filter treats the entire @loaded_set as input to that example;
    #     after each example, any newly-loaded path is attributed
    #     specifically to the just-completed example *and* added to
    #     @loaded_set for the benefit of subsequent examples.
    #
    # Rationale - why not smarter?
    # ----------------------------
    # The cheaper alternatives all fail correctness or cost:
    #   - TracePoint(:class, :c_return) fires on every C method call;
    #     orders-of-magnitude overhead.
    #   - Ruby-AST scans for constant references are unreliable under
    #     metaprogramming (const_get, send, autoload blocks).
    #   - Constant-table introspection doesn't tell us which *example*
    #     used which constant.
    #   - Stack-trace sampling is probabilistic - inappropriate for
    #     cache correctness.
    # The "loaded set" approach is the cheapest correct solution. Cost:
    # the test cache is slightly less selective (a lib/constants.rb
    # change re-runs every example that ran after it loaded rather than
    # just some subset). Correctness is the win.
    #
    # Input kind reuse
    # ----------------
    # Emits Input values with `kind: :ruby` - every file in the
    # loaded-set is a Ruby source file (`::Coverage` tracks Ruby only),
    # and the dependency graph keys on path (ignoring kind) so a
    # separate `:transitive_load` kind would buy nothing observable.
    # Overlap with CoverageAdapter's `:ruby` emissions dedupes naturally
    # at graph registration.
    #
    # Digest cache
    # ------------
    # Each path is digested at most once per run (first time it appears
    # in either the boot set or a stop_example diff). The cache backs
    # both `loaded_set_inputs` and `boot_set_digest_snapshot`, so
    # boot-set invalidation comparison is free after the initial capture.
    #
    # Enablement flag
    # ---------------
    # `enabled:` (default true) threads through from
    # Configuration#transitive_load_tracking. When false, every method
    # degrades to a no-op that returns empty collections. This gives
    # teams an opt-out for pathological suites where the transitive
    # over-approximation is too aggressive.
    class LoadedFilesTracker
      DEFAULT_PEEK = -> { ::Coverage.peek_result.keys }

      # boot_set is exposed as an attr_reader rather than a hand-
      # rolled method so RuboCop's Style/TrivialAccessors stays quiet;
      # nil is a valid "not yet captured" state callers rely on.
      attr_reader :root, :boot_set

      def initialize(root:, peek: DEFAULT_PEEK, enabled: true)
        @root = File.expand_path(root)
        @root_prefix = "#{@root}/"
        @peek = peek
        @enabled = enabled
        @boot_set = nil
        @loaded_set = Set.new
        @input_cache = {}
        # Steady-state fast-path cache for stop_example: ::Coverage's
        # tracked-file set grows monotonically; if peek_result.length
        # is unchanged since the last stop_example call, no new project
        # files can have appeared. Skip the per-path filter loop
        # entirely. Initialized to nil so the first call always falls
        # through to full work + populates the cache.
        @last_peek_length = nil
      end

      def enabled?
        @enabled
      end

      # Capture the boot set once. Idempotent: subsequent calls return
      # the frozen Set captured on the first call. When disabled,
      # returns an empty frozen Set without touching ::Coverage.
      #
      # Paths whose digest fails (unreadable files) are dropped on the
      # floor - they stay absent from @boot_set, @loaded_set, and
      # @input_cache, preserving the "every tracked path has an Input"
      # invariant. Downstream filtering accepts the slight under-count
      # (a truly-unreadable boot file was never going to be a useful
      # invalidation signal anyway).
      def capture_boot_set!
        return @boot_set unless @boot_set.nil?

        if @enabled
          successful_paths = build_inputs(filtered_peek_paths).each_with_object(Set.new) do |input, acc|
            acc << input.path
          end
          # Construct @loaded_set and @boot_set from distinct Set
          # instances so freezing one can't poison the other -
          # stop_example must be able to mutate @loaded_set forever
          # while @boot_set stays frozen for invalidator comparison.
          @loaded_set = successful_paths
          @boot_set = Set.new(successful_paths).freeze
        else
          @loaded_set = Set.new
          @boot_set = Set.new.freeze
        end
        @boot_set
      end

      # Hash[relative_path => sha256_hex] for every file in the boot
      # set. Used by the M3.6 caller to compare against the previous
      # run's stored `Snapshot.boot_set` - any inequality is a
      # whole-suite invalidator.
      #
      # Invariant (enforced by capture_boot_set!): every path in
      # @boot_set has a matching @input_cache entry, so the fetch
      # never raises. Disabled trackers produce an empty @boot_set,
      # so the enumeration naturally returns {} without a guard.
      def boot_set_digest_snapshot
        return {} if @boot_set.nil?

        @boot_set.to_h { |path| [relative_path(path), @input_cache.fetch(path).digest] }
      end

      # Compare the current boot set's digest snapshot against a
      # previously-stored one. `nil` previous_snapshot (first run, no
      # cache) is treated as "not invalidated by this signal" - first
      # run is already a cold run for unrelated reasons.
      #
      # Disabled tracker never invalidates - M3.6's caller ORs this
      # with WholeSuiteInvalidators.invalidated?, so returning false
      # keeps the tracker silent when the feature is off.
      def boot_set_invalidated?(previous_snapshot)
        return false unless @enabled
        return false if previous_snapshot.nil?

        boot_set_digest_snapshot != previous_snapshot
      end

      # Set<Input> covering the full @loaded_set. Callers merge this
      # into an example's Input bucket at start_example time - every
      # file loaded up to this point is a transitive dependency.
      # Returns a fresh Set per call so mutation stays local.
      #
      # Disabled trackers never populate @input_cache (capture_boot_set!
      # skips the build_inputs pass), so no explicit enabled guard is
      # needed - the enumeration naturally yields Set.new.
      def loaded_set_inputs
        @input_cache.values.to_set
      end

      # Diff-and-grow. Called after an example finishes: peeks
      # ::Coverage, finds paths the tracker hadn't seen yet, digests
      # them, adds them to @loaded_set + @input_cache, and returns the
      # new-paths-only Input set so the caller can attribute them to
      # the just-completed example.
      #
      # Paths whose digest fails are dropped from both @loaded_set and
      # the returned set - the next stop_example will retry them
      # (useful if the failure was transient) and keeps the
      # "@loaded_set => @input_cache has an entry" invariant.
      #
      # Steady state (no new files loaded this example) is ~O(|peek|)
      # with no digest work.
      def stop_example(_example_id)
        return Set.new unless @enabled

        new_paths = new_filtered_paths
        return Set.new if new_paths.empty?

        new_inputs = build_inputs(new_paths)
        @loaded_set.merge(new_inputs.map(&:path))
        new_inputs
      end

      # Defensive copy for external callers / property specs. Callers
      # that want read-only size should use `loaded_set_size` instead -
      # avoids the dup allocation.
      def loaded_set
        @loaded_set.dup
      end

      def loaded_set_size
        @loaded_set.size
      end

      private

      # Full filtered peek - returns a Set of every under-root String
      # path in the peek result. Used by capture_boot_set! (no prior
      # @loaded_set to diff against).
      def filtered_peek_paths
        @peek.call.each_with_object(Set.new) do |path, acc|
          acc << path if path.is_a?(String) && path.start_with?(@root_prefix)
        end
      rescue StandardError
        Set.new
      end

      # Diff-filtered peek - returns only paths not yet in @loaded_set.
      # One hash lookup per peek entry (vs. the two a Set.new + Set - Set
      # pipeline would pay). Halves stop_example steady-state cost.
      #
      # Steady-state fast-path: ::Coverage's tracked-file set grows
      # monotonically across the run, so when peek_result.length matches
      # the cached length from the previous call no new project paths
      # can have appeared. Returns [] without iterating - cuts the
      # per-call cost from ~70 us (full filter loop over ~500 paths) to
      # one Array#length comparison. M8.4-A profile pass identified
      # this loop as the dominant per-example cost in the engine
      # microbench (16% TOTAL); the fast-path drops it to <1%.
      def new_filtered_paths
        paths = @peek.call
        return [] if @last_peek_length == paths.length

        @last_peek_length = paths.length
        paths.each_with_object([]) do |path, acc|
          next unless path.is_a?(String)
          next unless path.start_with?(@root_prefix)
          next if @loaded_set.include?(path)

          acc << path
        end
      rescue StandardError
        []
      end

      # Builds Input objects for paths not yet cached; returns the Set
      # of Inputs produced for `paths` (may exclude entries whose
      # digest failed). Side effect: populates @input_cache.
      #
      # Callers are responsible for passing only paths absent from
      # @input_cache (capture_boot_set! on empty cache, stop_example
      # on `filtered_peek_keys - @loaded_set` where @loaded_set
      # mirrors @input_cache's keys modulo digest failures).
      def build_inputs(paths)
        paths.each_with_object(Set.new) do |path, acc|
          digest = file_digest(path)
          next if digest.nil?

          input = Input.for_file(path: path, kind: :ruby, digest: digest, root: @root)
          @input_cache[path] = input
          acc << input
        end
      end

      def file_digest(path)
        FileDigest.compute(path)
      end

      def relative_path(abs_path)
        return abs_path unless abs_path.start_with?(@root_prefix)

        abs_path[@root_prefix.length..]
      end
    end
  end
end
