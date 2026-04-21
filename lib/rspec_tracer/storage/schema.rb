# frozen_string_literal: true

module RSpecTracer
  module Storage
    # Cache schema version and compatibility policy. 1.x shipped caches
    # without any version stamp; 2.0's first migration is simply to
    # start emitting a version and refuse to load anything else.
    #
    # Compatibility rule (from ARCHITECTURE.md):
    #   - `CURRENT` is written into every new cache manifest.
    #   - `SUPPORTED` is the set of versions this backend is willing
    #     to load. For 2.0 there is exactly one supported version.
    #   - On mismatch, `load_graph` returns nil after an `info` log
    #     line and the run proceeds cold. No in-place migrators.
    #
    # Future version bumps (schema_version 3, 4, ...) add entries to
    # `SUPPORTED` only if the backend can load both shapes. If a
    # change is breaking, `SUPPORTED` resets to `[CURRENT]` and the
    # caller pays one cold run on upgrade - the deal 1.x users already
    # expect for any rspec-tracer version bump.
    module Schema
      # schema_version 2 shipped with M3.4 (first versioned schema;
      # 1.x was unstamped). M3.7 introduces `Snapshot.boot_set` -
      # breaking for any reader that assumed the v2 field list - so
      # CURRENT bumps to 3 and SUPPORTED narrows to only the new
      # version. Pre-release: no v2 caches are persisted in user land.
      CURRENT = 3
      SUPPORTED = [CURRENT].freeze

      # True when the caller can load a cache stamped with `version`.
      # nil (an unstamped 1.x cache) is explicitly unsupported -
      # treating nil as "compatible" would defeat the whole point of
      # the version field. The caller logs and falls back to cold run.
      def self.supported?(version)
        SUPPORTED.include?(version)
      end
    end
  end
end
