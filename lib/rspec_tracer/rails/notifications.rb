# frozen_string_literal: true

require_relative '../tracker/file_digest'
require_relative '../tracker/input'

module RSpecTracer
  # Internal Rails — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Rails
    # ActiveSupport::Notifications observer for Rails-side inputs that
    # Coverage and IOHooks can't see directly. Subscribes to:
    #
    #   - render_template.action_view   -> :template
    #   - render_partial.action_view    -> :template
    #   - render_collection.action_view -> :template (Rails 7.1+)
    #   - sql.active_record             -> :notification
    #       (on the first query per example, emits db/schema.rb +
    #        db/structure.sql as inputs)
    #
    # Lifecycle mirrors IOHooks: Engine.setup installs, example_started
    # opens a thread-local bucket, subscribers append, example_finished
    # harvests and clears the bucket, Engine.finalize unsubscribes.
    #
    # Payload access is defensively permissive - Rails minors differ on
    # symbol vs string keys; missing payload or nil identifier is
    # swallowed. Errors inside subscribers never propagate (CLAUDE.md
    # "graceful degradation").
    #
    # Precedence: an observed template path already covered by a user
    # declared glob (e.g. the Preset :views glob) skips notification
    # emission via the injected `filter:` callable. Matches IOHooks'
    # declared-glob-precedence rule from ARCHITECTURE.md.
    #
    # The sql.active_record subscriber is only attached when the caller
    # passes a non-empty `ar_schema_paths:` list. Engine resolves the
    # list from the `track_ar_schema_notifications` opt-in DSL; absent
    # that, the AR subscriber is never installed and the sql.active_record
    # event stream is ignored.
    class Notifications
      # Internal constant.
      # @api private
      BUCKET_KEY = :rspec_tracer_rails_bucket
      # Internal constant.
      # @api private
      AR_FLAG_KEY = :rspec_tracer_rails_ar_emitted

      class << self
        # Internal attribute.
        # @api private
        attr_reader :root

        # Internal method on the tracer pipeline.
        # @api private
        def install(root:, filter: ->(_path) { true }, ar_schema_paths: [])
          @root = File.expand_path(root)
          @root_prefix = "#{@root}/"
          @filter = filter
          @ar_schema_inputs = build_schema_inputs(ar_schema_paths)
          @handles = []

          subscribe_render_template
          subscribe_render_partial
          subscribe_render_collection if render_collection_supported?
          subscribe_sql_active_record if ar_enabled?

          self
        end

        # Internal method on the tracer pipeline.
        # @api private
        def uninstall
          (@handles || []).each { |handle| safely_unsubscribe(handle) }
          @handles = nil
          @root = nil
          @root_prefix = nil
          @filter = nil
          @ar_schema_inputs = nil
          self
        end

        # Internal method on the tracer pipeline.
        # @api private
        def installed?
          !@root_prefix.nil?
        end

        # rubocop:disable Naming/AccessorMethodName
        def set_bucket(bucket)
          Thread.current[BUCKET_KEY] = bucket
          Thread.current[AR_FLAG_KEY] = false
        end
        # rubocop:enable Naming/AccessorMethodName

        def clear_bucket
          Thread.current[BUCKET_KEY] = nil
          Thread.current[AR_FLAG_KEY] = nil
        end

        # Internal method on the tracer pipeline.
        # @api private
        def current_bucket
          Thread.current[BUCKET_KEY]
        end

        # Pure-logic entry point for the render_*.action_view
        # subscribers. Extracted so mutation smoke can exercise
        # payload parsing without driving AS::Notifications.
        def handle_render_event(payload)
          return nil unless payload.is_a?(Hash)

          identifier = payload[:identifier] || payload['identifier']
          return nil if identifier.nil?

          record_template(identifier)
        end

        # Pure-logic entry point for the sql.active_record subscriber.
        # Payload contents are ignored - the event itself is the
        # "this example touched AR" signal.
        def handle_sql_event(_payload)
          record_ar_schema
        end

        # Record a :template Input for the observed render identifier.
        # Guarded by the same fast-reject ladder as IOHooks: install
        # state, bucket presence, path-under-root, filter callable,
        # identity dedup. The early-return ladder looks complex to
        # rubocop's metric but is the simplest shape for a hot path.
        # rubocop:disable Metrics/PerceivedComplexity
        def record_template(path)
          return nil if @root_prefix.nil?

          bucket = Thread.current[BUCKET_KEY]
          return nil if bucket.nil?
          return nil unless path.is_a?(String) || path.respond_to?(:to_s)

          path_str = path.to_s
          return nil unless path_str.start_with?(@root_prefix)
          return nil unless @filter.call(path_str)

          identity = "template:#{path_str[@root_prefix.length..]}"
          return nil if bucket.key?(identity)

          digest = Tracker::FileDigest.compute(path_str)
          return nil if digest.nil?

          bucket[identity] = Tracker::Input.for_file(
            path: path_str, kind: :template, digest: digest, root: @root
          )
        rescue StandardError
          nil
        end
        # rubocop:enable Metrics/PerceivedComplexity

        # Emit the pre-digested schema Inputs into the bucket on the
        # first sql.active_record event per example. Subsequent events
        # short-circuit via AR_FLAG_KEY - O(1) after the first query.
        def record_ar_schema
          return nil if @ar_schema_inputs.nil? || @ar_schema_inputs.empty?

          bucket = Thread.current[BUCKET_KEY]
          return nil if bucket.nil?
          return nil if Thread.current[AR_FLAG_KEY]

          Thread.current[AR_FLAG_KEY] = true
          @ar_schema_inputs.each do |input|
            bucket[input.identity] ||= input
          end
          nil
        rescue StandardError
          nil
        end

        private

        # Internal method on the tracer pipeline.
        # @api private
        def ar_enabled?
          !(@ar_schema_inputs.nil? || @ar_schema_inputs.empty?)
        end

        # Internal method on the tracer pipeline.
        # @api private
        def subscribe_render_template
          @handles << ::ActiveSupport::Notifications.subscribe('render_template.action_view') do |*args|
            handle_render_event(args.last)
          end
        end

        # Internal method on the tracer pipeline.
        # @api private
        def subscribe_render_partial
          @handles << ::ActiveSupport::Notifications.subscribe('render_partial.action_view') do |*args|
            handle_render_event(args.last)
          end
        end

        # Internal method on the tracer pipeline.
        # @api private
        def subscribe_render_collection
          @handles << ::ActiveSupport::Notifications.subscribe('render_collection.action_view') do |*args|
            handle_render_event(args.last)
          end
        end

        # Internal method on the tracer pipeline.
        # @api private
        def subscribe_sql_active_record
          @handles << ::ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
            handle_sql_event(args.last)
          end
        end

        # Rails 7.1 added render_collection.action_view. Subscribing to
        # a non-existent event silently no-ops on modern AS, but the
        # version check keeps `@handles` tight for uninstall accounting.
        def render_collection_supported?
          return false unless defined?(::Rails::VERSION::STRING)

          Gem::Version.new(::Rails::VERSION::STRING) >= Gem::Version.new('7.1')
        rescue StandardError
          false
        end

        # Pre-digest the schema paths at install time. An unreadable or
        # missing file is dropped on the floor - graceful degradation.
        # Returns a frozen array so record_ar_schema can iterate without
        # defensive dup.
        def build_schema_inputs(paths)
          Array(paths).each_with_object([]) do |path, acc|
            input = try_build_schema_input(path)
            acc << input if input
          end.freeze
        end

        # Internal method on the tracer pipeline.
        # @api private
        def try_build_schema_input(path)
          abs = File.expand_path(path.to_s, @root)
          return nil unless abs.start_with?(@root_prefix)
          return nil unless File.file?(abs)

          digest = Tracker::FileDigest.compute(abs)
          return nil if digest.nil?

          Tracker::Input.for_file(
            path: abs, kind: :notification, digest: digest, root: @root
          )
        rescue StandardError
          nil
        end

        # Internal method on the tracer pipeline.
        # @api private
        def safely_unsubscribe(handle)
          ::ActiveSupport::Notifications.unsubscribe(handle)
        rescue StandardError
          nil
        end
      end
    end
  end
end
