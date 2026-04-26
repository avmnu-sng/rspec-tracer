# frozen_string_literal: true

require 'digest'
require 'set'

require_relative 'input'
# Sub-module hooks loaded eagerly: $LOADED_FEATURES makes require
# idempotent so placement doesn't change observable behavior, and
# Engine always calls IOHooks.install at boot - the previous
# install-time require_relative deferred a load that always fires
# anyway, paying the same total cost ~5 ms later at the cost of
# the standard requires-at-top Ruby convention.
require_relative 'io_hooks/file'
require_relative 'io_hooks/io'
require_relative 'io_hooks/yaml'
require_relative 'io_hooks/json'
require_relative 'io_hooks/kernel'

module RSpecTracer
  module Tracker
    # Observer #2 in the 2.0 tracker pipeline (CoverageAdapter is #1).
    # Intercepts Ruby's file-reading primitives via Module#prepend and
    # emits Tracker::Input values for files touched by the currently-
    # active example.
    #
    # Lifecycle:
    #   1. IOHooks.install(root:, filter:, extensions:) - called once
    #      at Tracker.setup time (wired in M3.6). Prepends hook modules
    #      onto File/IO/YAML/JSON/Kernel singleton classes.
    #   2. Example execution runs inside IOHooks.with_bucket(bucket)
    #      {...}. Hooks push Inputs into the thread-local bucket;
    #      outside a with_bucket call every hook fast-rejects.
    #   3. IOHooks.uninstall clears state - prepended modules stay in
    #      the ancestry (Ruby has no public API to remove a prepend),
    #      but every hook fast-rejects on the nil @root_prefix guard,
    #      so post-uninstall they're functionally no-ops.
    #
    # Hot-path rejection order (cheapest first):
    #   1. @root_prefix present        (install state)
    #   2. thread-local bucket present (inside an example)
    #   3. path is String / to_s-able
    #   4. path.start_with?(@root_prefix)
    #   5. allow-predicate (extensions + filter, or .rb for Kernel)
    #   6. bucket.key?(identity)       (dedup before SHA256)
    #
    # Digest is SHA256 hex (same as CoverageAdapter; schema_version
    # bump to change). Computed only *after* dedup, so a file read N
    # times in one example pays the SHA256 cost exactly once.
    module IOHooks
      # Non-Ruby extensions the hook is interested in. .rb is covered
      # by CoverageAdapter, so it's excluded from the default :data
      # allow-set. Kernel#load uses a separate predicate (.rb only).
      DEFAULT_EXTENSIONS = %w[
        .yml .yaml .json .erb .haml .slim .builder .jbuilder .ru .rake
      ].to_set.freeze

      BUCKET_KEY = :rspec_tracer_io_bucket
      # Re-entry guard: Digest::SHA256.file internally opens the file,
      # which re-fires the File.open hook. Without this flag, the
      # first hooked read blows the stack via infinite recursion.
      REENTRY_KEY = :rspec_tracer_io_in_hook

      class << self
        attr_reader :root

        def install(root:, filter: ->(_path) { true }, extensions: DEFAULT_EXTENSIONS)
          @root = File.expand_path(root)
          @root_prefix = "#{@root}/"
          @extensions = extensions
          @filter = filter

          ::File.singleton_class.prepend(FileReads)
          ::IO.singleton_class.prepend(IOReads)
          ::YAML.singleton_class.prepend(YAMLReads) if defined?(::YAML)
          ::JSON.singleton_class.prepend(JSONReads) if defined?(::JSON)
          # Two prepends: singleton_class catches `Kernel.load('x')`,
          # the module itself catches implicit `load 'x'` in method
          # bodies (via Object's ancestor chain). `module_function`
          # on Kernel creates two separate method objects, so both
          # dispatch paths must be instrumented independently.
          ::Kernel.singleton_class.prepend(KernelReads)
          ::Kernel.prepend(KernelReads)

          self
        end

        def uninstall
          @root = nil
          @root_prefix = nil
          @extensions = nil
          @filter = nil
          self
        end

        def installed?
          !@root_prefix.nil?
        end

        def current_bucket
          Thread.current[BUCKET_KEY]
        end

        def with_bucket(bucket)
          prev = Thread.current[BUCKET_KEY]
          Thread.current[BUCKET_KEY] = bucket
          begin
            yield
          ensure
            Thread.current[BUCKET_KEY] = prev
          end
        end

        # Non-block lifecycle for integration with RSpec hooks (which
        # can't wrap the example body in a Ruby block). The Tracker
        # coordinator calls set_bucket at example_started time and
        # clear_bucket at example_finished time. Unlike with_bucket,
        # these do not save/restore a prior bucket - the coordinator
        # owns the Thread.current slot for the span of an example.
        # rubocop:disable Naming/AccessorMethodName
        def set_bucket(bucket)
          Thread.current[BUCKET_KEY] = bucket
        end
        # rubocop:enable Naming/AccessorMethodName

        def clear_bucket
          Thread.current[BUCKET_KEY] = nil
        end

        # Record a :data input (File/IO/YAML/JSON hooks). The
        # allow-predicate is the coordinator's default extension +
        # filter combo.
        def record(path)
          _record(path, :data) do |p|
            @extensions.include?(File.extname(p)) && @filter.call(p)
          end
        end

        # Record a :ruby input (Kernel#load hook). Belt-and-suspenders
        # for dynamically-constructed load paths that might bypass the
        # Coverage module's require-graph observation. M3.5's registry
        # dedupes overlap with CoverageAdapter.
        def record_ruby_load(path)
          _record(path, :ruby) { |p| p.end_with?('.rb') }
        end

        private

        # All hook entrypoints funnel through here. Fast-path order is
        # tuned for the common case (hook fires, there's no bucket):
        # do the cheapest checks first and bail before touching any
        # allocation. Only on the slow path do we set the re-entry
        # guard - `Digest::SHA256.file` internally opens the file and
        # would otherwise blow the stack.
        #
        # Any error is swallowed - hooks never propagate failure into
        # the user's test suite (CLAUDE.md "graceful degradation").
        #
        # The early-return ladder looks complex to RuboCop's metric
        # but is actually the simplest shape for a hot path: each
        # guard rejects in ~1-2 machine ops.
        # rubocop:disable Metrics/PerceivedComplexity
        def _record(path, kind)
          return if @root_prefix.nil?

          bucket = Thread.current[BUCKET_KEY]
          return if bucket.nil?
          return unless path.is_a?(String) || path.respond_to?(:to_s)

          path_str = path.to_s
          return unless path_str.start_with?(@root_prefix)
          return unless yield(path_str)

          identity = "#{kind}:#{path_str[@root_prefix.length..]}"
          return if bucket.key?(identity)
          return if Thread.current[REENTRY_KEY]

          Thread.current[REENTRY_KEY] = true
          begin
            digest = Digest::SHA256.file(path_str).hexdigest
            bucket[identity] = Input.for_file(
              path: path_str, kind: kind, digest: digest, root: @root
            )
          ensure
            Thread.current[REENTRY_KEY] = false
          end
        rescue StandardError
          nil
        end
        # rubocop:enable Metrics/PerceivedComplexity
      end
    end
  end
end
