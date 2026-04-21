# frozen_string_literal: true

require 'digest'

require_relative '../version'

module RSpecTracer
  module Tracker
    # Observer #4 in the 2.0 tracker pipeline. Emits the binary
    # "blow it all up" signal that runs before any per-example
    # filtering - when any watched file changes, the filter engine
    # (M3.5) treats every example as affected.
    #
    # Watch list is deliberately hard-coded (not config-overridable):
    # these are the files whose semantics are universal across any
    # rspec-tracer user.
    #
    #   - Gemfile.lock   : dependency changes ripple through every spec
    #   - .ruby-version  : Ruby version changes can shift any behavior
    #   - .rspec-tracer  : tracer config changes (filters, declared
    #                      globs) affect what the cache considers fresh
    #
    # Plus a synthetic entry for the rspec-tracer gem identity itself -
    # a gem upgrade that changes invalidation semantics has to
    # invalidate the cache, which lockfile tracking alone doesn't catch
    # (the gem path is version-stamped but Gemfile.lock only sees the
    # constraint, not the resolved install).
    #
    # Graceful degradation (CLAUDE.md): absent watch files are skipped
    # silently. Key-presence asymmetry is the invalidation signal
    # (snapshot A has key, snapshot B does not => invalidated).
    class WholeSuiteInvalidators
      WATCH_FILES = %w[Gemfile.lock .ruby-version .rspec-tracer].freeze
      GEM_IDENTITY_KEY = 'rspec-tracer-gem'

      attr_reader :root, :gem_version

      def initialize(root:, gem_version: RSpecTracer::VERSION)
        @root = File.expand_path(root)
        @gem_version = gem_version
      end

      # Fresh snapshot on every call - callers typically take one at
      # boot (stored as the "current" snapshot) and compare against a
      # previously-loaded snapshot (returned by storage in M3.4).
      # Unlike DeclaredGlobs.walk, this is not memoized: the caller
      # chooses when to sample.
      def digest_snapshot
        snapshot = {}
        WATCH_FILES.each do |rel|
          digest = file_digest(File.join(@root, rel))
          snapshot[rel] = digest unless digest.nil?
        end
        snapshot[GEM_IDENTITY_KEY] = gem_identity_digest
        snapshot
      end

      # nil previous_snapshot = first-run case (no cache); treat as
      # invalidated so the filter engine runs every example. Any
      # subsequent run with a stored snapshot compares value-equality
      # across the whole Hash, which captures added/removed/changed
      # watch files in one check.
      def invalidated?(previous_snapshot)
        return true if previous_snapshot.nil?

        digest_snapshot != previous_snapshot
      end

      private

      # Digest::SHA256.file raises SystemCallError for missing / non-file
      # paths; the rescue normalizes the outcome so the existence check
      # is implicit. Mirrors CoverageAdapter#file_digest's rescue-only
      # shape.
      def file_digest(path)
        Digest::SHA256.file(path).hexdigest
      rescue SystemCallError
        nil
      end

      def gem_identity_digest
        Digest::SHA256.hexdigest("rspec-tracer-#{@gem_version}")
      end
    end
  end
end
