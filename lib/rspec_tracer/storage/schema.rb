# frozen_string_literal: true

module RSpecTracer
  # Internal Storage — see {RSpecTracer} for the user-facing surface.
  # @api private
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
      # 1.x caches were unstamped; schema_version 2 was the first
      # versioned schema, and 2.0 bumped to 3 when `Snapshot.boot_set`
      # landed. schema_version 4 changes the example-identity payload:
      # `example_id` now hashes the describe block's *description*
      # (not RSpec's load-order-dependent class name) and excludes
      # line numbers, so a 3-stamped cache's example_ids no longer
      # match. The change is breaking, so SUPPORTED stays `[CURRENT]`
      # and the caller pays one cold run on upgrade.
      CURRENT = 4
      # Internal constant.
      # @api private
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
