# frozen_string_literal: true

require 'digest'

module RSpecTracer
  # Internal Tracker — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Tracker
    # Process-wide SHA256 file-digest cache. Keyed on absolute path
    # with [mtime_ns, size] as the freshness check — when the file's
    # stat timestamps + size match the cached values, the prior
    # digest is reused; otherwise the digest is recomputed and the
    # cache entry refreshed.
    #
    # The cache is populated lazily and never evicted within a
    # process. Tracer runs are bounded (one rspec invocation per
    # process), so unbounded growth is bounded by the project's
    # dependency-graph size (typically << 10k unique files).
    #
    # SystemCallError on stat / digest is treated as "file gone /
    # unreadable" and returns nil — same graceful-degradation
    # contract every call site already implemented locally before
    # this module centralized them.
    #
    # Thread-safety: rspec example execution is single-threaded
    # (cold-subprocess contract); the cache uses a plain Hash without
    # locking. Multi-threaded callers are unsupported (consistent
    # with the rest of the tracer's threading model).
    module FileDigest
      class << self
        # Returns the SHA256 hex digest of `path`, or nil when the
        # file can't be stat'd (missing / permission denied / racey
        # delete). Subsequent calls for the same path with unchanged
        # stat skip the digest computation entirely.
        def compute(path)
          stat = File.stat(path)
          key = (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec
          size = stat.size
          cache = (@cache ||= {})
          cached = cache[path]
          return cached[2] if cached && cached[0] == key && cached[1] == size

          digest = Digest::SHA256.file(path).hexdigest
          cache[path] = [key, size, digest]
          digest
        rescue SystemCallError
          nil
        end

        # Drop the cache. Tests that mutate file content in-place at
        # nanosecond granularity (and so might collide on the
        # mtime+size key) should call this between scenarios. Normal
        # tracer runs never need it — the cache lives for one
        # rspec invocation only.
        def reset!
          @cache = {}
        end
      end
    end
  end
end
