# frozen_string_literal: true

require 'set'

module RSpecTracer
  # Internal Tracker — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Tracker
    # Directed bipartite graph over (example_id, file path). The
    # forward map answers "which files does this example depend on?";
    # the memoized inverse answers "which examples depend on this
    # file?" in O(1) per lookup.
    #
    # The graph is append-only during a run. `register_example` is
    # called once per example at example-finished time with the Input
    # set that CoverageAdapter + IOHooks + DeclaredGlobs collected.
    # The inverse is invalidated on every register_example and lazily
    # rebuilt on the next `examples_depending_on` call.
    #
    # Keyed by file path, not Input identity
    # -------------------------------------
    # An earlier design framed the inverse as "input_identity -> Set<example_id>",
    # which embeds the Input#kind (e.g. "ruby:lib/foo.rb" vs
    # "declared:lib/foo.rb"). In practice the change-set that drives
    # filtering comes from diffing Snapshot.all_files digests, which
    # is keyed by path only - the kind that observed the file is not
    # recoverable from a digest mismatch. Keying the graph by path
    # eliminates that recovery burden and matches 1.x's
    # dependency.json shape exactly (Hash[example_id => Set<path>]),
    # keeping the Snapshot byte-compatible. Kind-aware filtering, if
    # ever needed, can layer on top without changing the graph shape.
    #
    # API accepts Set<Input>, Set<String>, or any mix - anything that
    # responds to :path is treated as an Input; otherwise `.to_s`.
    # This keeps observer call sites terse (pass the Input set
    # directly) without forcing Snapshot-load sites to reconstruct
    # Input objects from paths.
    class DependencyGraph
      # Internal method on the tracer pipeline.
      # @api private
      def initialize
        @forward = {}
        @inverse_index = nil
      end

      # Internal method on the tracer pipeline.
      # @api private
      def register_example(example_id, inputs)
        @forward[example_id] = coerce_paths(inputs)
        @inverse_index = nil
        self
      end

      # Internal method on the tracer pipeline.
      # @api private
      def paths_for(example_id)
        @forward[example_id] || Set.new
      end

      # Internal method on the tracer pipeline.
      # @api private
      def example_ids
        @forward.keys
      end

      # Internal method on the tracer pipeline.
      # @api private
      def empty?
        @forward.empty?
      end

      # O(|change_set| x avg-examples-per-file). `change_set` can be
      # a Set<Input>, Set<String>, or any mix - coerced the same way
      # `register_example` coerces its inputs arg.
      def examples_depending_on(change_set)
        return Set.new if @forward.empty?

        paths = coerce_paths(change_set)
        return Set.new if paths.empty?

        affected = Set.new
        paths.each do |path|
          ids = inverse_index[path]
          affected.merge(ids) if ids
        end
        affected
      end

      # Snapshot projection. `dependency_hash` feeds
      # Snapshot.dependency; `reverse_dependency_hash` feeds
      # Snapshot.reverse_dependency. Both return fresh Sets per value
      # so downstream mutation can't leak into the graph's state.
      def dependency_hash
        @forward.transform_values(&:dup)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def reverse_dependency_hash
        inverse_index.transform_values(&:dup)
      end

      private

      # Internal method on the tracer pipeline.
      # @api private
      def coerce_paths(collection)
        return Set.new if collection.nil?

        collection.each_with_object(Set.new) do |entry, acc|
          acc << (entry.respond_to?(:path) ? entry.path : entry.to_s)
        end
      end

      # Internal method on the tracer pipeline.
      # @api private
      def inverse_index
        @inverse_index ||= build_inverse_index
      end

      # Internal method on the tracer pipeline.
      # @api private
      def build_inverse_index
        map = {}
        @forward.each do |example_id, paths|
          paths.each do |path|
            (map[path] ||= Set.new) << example_id
          end
        end
        map
      end
    end
  end
end
