# frozen_string_literal: true

require 'set'

module RSpecTracer
  # Internal RSpec — see {RSpecTracer} for the user-facing surface.
  # @api private
  module RSpec
    # Per-example tracking DSL. Reads the `tracks:` metadata key
    # off an example and its ancestor example groups and emits a
    # normalized union of declared file globs + env-var names.
    #
    # DSL shape (user-facing):
    #
    #   RSpec.describe 'AdminController',
    #                  tracks: { files: 'app/policies/**/*.rb', env: 'ROLE_CONFIG' } do
    #     ...
    #   end
    #
    # Values for `:files` and `:env` accept either a single String or
    # an Array of Strings. Nested groups each contribute their own
    # tracks hash; the union (not the replace) is what the example
    # inherits. RSpec's built-in metadata cascade uses Hash#merge
    # which would clobber a parent `tracks:` with a child `tracks:`
    # on a shared key - almost never the user's intent. `tracks_for`
    # bypasses the auto-cascade and walks ancestors explicitly.
    #
    # Returns `{ files: Set<String>, env: Set<String> }`. Empty sets
    # when nothing is declared - callers can short-circuit on
    # `result[:files].empty? && result[:env].empty?` to skip the
    # attribution/env-snapshot plumbing.
    #
    # Pure-function (module-level, no state). Safe to call from the
    # RunnerHook filter loop without synchronization.
    module Metadata
      # Internal constant.
      # @api private
      TRACKS_KEY = :tracks
      # Internal constant.
      # @api private
      FILES_KEY = :files
      # Internal constant.
      # @api private
      ENV_KEY = :env

      # Keep methods module-level via `def self.x` (not module_function)
      # so mutant can observe them - module_function attaches the
      # methods to an anonymous singleton that Method#source_location
      # can't trace.
      def self.tracks_for(example)
        files = Set.new
        envs = Set.new

        collect(example.example_group.parent_groups, files, envs)
        merge_hash(example.metadata[TRACKS_KEY], files, envs)

        { FILES_KEY => files, ENV_KEY => envs }
      end

      # parent_groups returns outer-first. Walk from outer to inner so
      # the set-union is order-agnostic anyway; the order is
      # documented for future readers who need it deterministic.
      def self.collect(parent_groups, files, envs)
        parent_groups.reverse_each do |group|
          merge_hash(group.metadata[TRACKS_KEY], files, envs)
        end
      end

      # A `tracks:` value of nil, non-Hash, or an empty Hash contributes
      # nothing. Non-Hash values are silently ignored - tolerating
      # user typos over raising is consistent with the rest of the
      # DSL surface (add_filter, coverage_track_files).
      def self.merge_hash(tracks, files, envs)
        return unless tracks.is_a?(Hash)

        normalize(tracks[FILES_KEY]).each { |v| files << v }
        normalize(tracks[ENV_KEY]).each { |v| envs << v }
      end

      # String -> [String]; Array -> itself; anything else -> []. nil,
      # empty-string, and blank values are filtered so
      # `tracks: { files: '', env: nil }` doesn't inject empty entries
      # into the attribution set.
      def self.normalize(value)
        case value
        when String
          value.empty? ? [] : [value]
        when Array
          value.map(&:to_s).reject(&:empty?)
        else
          []
        end
      end
    end
  end
end
