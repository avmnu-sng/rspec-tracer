# frozen_string_literal: true

require_relative '../tracker/file_digest'
require_relative '../tracker/input'
require_relative 'notifications'

module RSpecTracer
  module Rails
    # I18n backend observer. Covers custom backends (Redis-backed,
    # DB-backed, Chain) that bypass YAML.load_file and would otherwise
    # miss the M3.2 IOHooks YAML hook.
    #
    # Mechanism: Module#prepend onto ::I18n::Backend::Base - every
    # backend subclass's load_translations resolves through the hook,
    # even when the subclass overrides and super-calls Base. Backends
    # that never super-call Base#load_translations fall through the
    # hook, but the common backends (Simple, Chain, Cascade) all do.
    #
    # Shares Notifications' thread-local bucket so Engine.setup opens
    # and clears one bucket per example that covers both observer
    # families. Engine harvests `bucket.values` at example_finished.
    #
    # Graceful degradation:
    # - install no-ops if ::I18n::Backend::Base is absent (tracer
    #   boot survives even in weird I18n-free app graphs).
    # - Every record call swallows StandardError (CLAUDE.md) - a
    #   digest failure or bucket-shape surprise never propagates into
    #   the user's test run.
    class I18nTracking
      class << self
        attr_reader :root

        def install(root:, filter: ->(_path) { true })
          @root = File.expand_path(root)
          @root_prefix = "#{@root}/"
          @filter = filter
          @prepended = prepend_backend_hook

          self
        end

        # Prepended modules cannot be removed from the ancestry chain
        # (Ruby has no public API), mirroring IOHooks.uninstall. Every
        # hook entry point fast-rejects on @root_prefix nil once
        # install state clears, so post-uninstall the hook is a no-op.
        def uninstall
          @root = nil
          @root_prefix = nil
          @filter = nil
          @prepended = false
          self
        end

        def installed?
          !@root_prefix.nil?
        end

        # Called from LoadTranslationsHook for every filename passed
        # to I18n::Backend::Base#load_translations. Array form keeps
        # the hook a single call site.
        def record_translations(filenames)
          return nil if @root_prefix.nil?

          Array(filenames).each { |path| record_translation(path) }
          nil
        end

        # Pure-logic entry point. Same fast-reject ladder as
        # Notifications#record_template. Emits :notification kind
        # so the I18n source is distinguishable from template events
        # in downstream reporters. The ladder is longer than rubocop's
        # perceived-complexity threshold by design - each guard is a
        # cheap fast-reject.
        # rubocop:disable Metrics/PerceivedComplexity
        def record_translation(path)
          return nil if @root_prefix.nil?

          bucket = Notifications.current_bucket
          return nil if bucket.nil?
          return nil unless path.is_a?(String) || path.respond_to?(:to_s)

          path_str = path.to_s
          return nil unless path_str.start_with?(@root_prefix)
          return nil unless @filter.call(path_str)

          identity = "notification:#{path_str[@root_prefix.length..]}"
          return nil if bucket.key?(identity)

          digest = Tracker::FileDigest.compute(path_str)
          return nil if digest.nil?

          bucket[identity] = Tracker::Input.for_file(
            path: path_str, kind: :notification, digest: digest, root: @root
          )
        rescue StandardError
          nil
        end
        # rubocop:enable Metrics/PerceivedComplexity

        private

        def prepend_backend_hook
          return false unless defined?(::I18n::Backend::Base)

          ::I18n::Backend::Base.prepend(LoadTranslationsHook)
          true
        rescue StandardError
          false
        end
      end

      # Prepended onto I18n::Backend::Base. Every subclass's
      # load_translations ultimately resolves through here via super.
      # Intercepts the filename list, delegates recording to the
      # singleton, and forwards to the real implementation.
      module LoadTranslationsHook
        def load_translations(*filenames)
          RSpecTracer::Rails::I18nTracking.record_translations(filenames)
          super
        end
      end
    end
  end
end
