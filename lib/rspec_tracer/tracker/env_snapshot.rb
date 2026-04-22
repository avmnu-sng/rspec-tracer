# frozen_string_literal: true

require 'digest/md5'
require 'set'

module RSpecTracer
  module Tracker
    # Observer #5 in the 2.0 tracker pipeline (WholeSuiteInvalidators
    # is #4). Owns the per-run snapshot of environment-variable
    # values that M5.2's `tracks: { env: ... }` metadata declares.
    #
    # Watch list is caller-provided - unlike WholeSuiteInvalidators,
    # which hard-codes Gemfile.lock / .ruby-version / .rspec-tracer,
    # env names come from user metadata and are only known once
    # RSpec has discovered every example. The engine unions every
    # example's declared env names and hands the set to
    # `digest_snapshot` at finalize time.
    #
    # Digest algorithm: `Digest::MD5.hexdigest(ENV[name].to_s)`.
    # Missing env var digests the same as empty string - absent is a
    # valid state. ENV is process-stable within a single run (we
    # never mutate it mid-run), so one snapshot per run is enough.
    #
    # Graceful degradation: the observer never raises on malformed
    # input. Non-String env names are coerced via #to_s; nil / empty
    # names are skipped silently.
    class EnvSnapshot
      # ENV source is injectable for testability - specs can pass a
      # Hash double without poking the real process env.
      def initialize(env: ::ENV)
        @env = env
      end

      # Snapshot the current ENV values for `names`. Returns
      # `Hash[name => md5_hex]`. Idempotent; callers may invoke it
      # repeatedly without side effects.
      def digest_snapshot(names)
        snapshot = {}
        names.each do |raw|
          key = raw.to_s
          next if key.empty?

          snapshot[key] = Digest::MD5.hexdigest(@env[key].to_s)
        end
        snapshot
      end

      # Return the set of env names whose digest differs between
      # `previous_snapshot` and the current ENV. Keys in either
      # snapshot participate:
      #
      #   - present in both, digests differ  => invalidated
      #   - present in previous, absent now  => invalidated
      #   - absent previously, present now   => invalidated
      #
      # `previous_snapshot` may be nil (first run, no cache); in that
      # case every currently-tracked key is considered invalidated so
      # the examples declaring them get a mandatory cold re-run on
      # first sighting. `names` scopes the check: only keys in
      # `names` are considered, which means one example adding a new
      # `tracks: env: ...` doesn't cascade-invalidate examples that
      # declared different env keys previously.
      def invalidated_keys(previous_snapshot, names)
        previous = previous_snapshot || {}
        current = digest_snapshot(names)
        invalidated = Set.new

        current.each do |key, digest|
          invalidated << key if digest != previous[key]
        end
        invalidated
      end
    end
  end
end
