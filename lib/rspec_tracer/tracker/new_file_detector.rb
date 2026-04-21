# frozen_string_literal: true

require 'set'

require_relative 'declared_globs'

module RSpecTracer
  module Tracker
    # Observer #5 (composition of DeclaredGlobs + cache diff). Fixes
    # KNOWN_ISSUES Section B5: 1.x's fetch_changed_files loop only
    # iterated the previous run's cache, so newly-added source files
    # were never discovered and never triggered re-runs.
    #
    # The fix: at boot, walk the union of user-declared globs and a
    # pure-Ruby default set (lib/**/*.rb). Every match on disk that is
    # not in the loaded cache's known_paths emits an Input, which the
    # filter engine (M3.5) treats as "added" and re-runs any example
    # whose dependency graph could plausibly include it.
    #
    # Kind is :declared for every emission. The pure-Ruby default is
    # logically a pre-declared glob on the user's behalf - the
    # attribution semantics are identical to an explicit
    # `track_files 'lib/**/*.rb'`.
    #
    # Rails preset (app/**/*.rb) arrives in M4.1 through
    # Configuration#track_rails_defaults; the default list here stays
    # framework-agnostic.
    class NewFileDetector
      DEFAULT_GLOBS = %w[lib/**/*.rb].freeze

      attr_reader :root

      def initialize(root:, declared_globs: [], default_globs: DEFAULT_GLOBS)
        @root = File.expand_path(root)
        merged = Array(declared_globs).flatten.compact.map(&:to_s) +
          Array(default_globs).flatten.compact.map(&:to_s)
        @walker = DeclaredGlobs.new(root: @root, globs: merged.uniq)
      end

      # Set<Input> for every on-disk match not present in the supplied
      # known_paths Set. Called once per suite boot; the walker's
      # underlying digest work is memoized on the DeclaredGlobs
      # instance so repeated calls within a single suite don't re-hash.
      def new_files(known_paths:)
        known = known_paths.to_set
        @walker.walk.reject { |input| known.include?(input.path) }.to_set
      end
    end
  end
end
