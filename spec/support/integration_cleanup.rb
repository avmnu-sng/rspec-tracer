# frozen_string_literal: true

require 'fileutils'

# Shared cleanup helper for integration / edge-case specs that drive
# the tracer end-to-end against the real filesystem. Call from
# before(:all) and after(:all) hooks to scrub cache / report /
# coverage state between back-to-back runs.
#
# Closes a recurring flake pattern: stale cache-state leaking
# between back-to-back integration runs. The
# Taskfile does not rm -rf cache/report dirs between tasks, so a spec
# whose fixture leaks state into the next spec used to surface as
# flakes that disappeared after a manual `rm -rf`.
#
# Shape: explicit class methods, NOT an auto-include via metadata.
# Each spec passes the paths it cares about so cleanup scope is
# visible in the spec source - auto-include hides which paths get
# scrubbed and risks cross-spec leaks.
#
# Graceful-degradation contract: a failure on one path does NOT
# abort cleanup of the others. Same posture the storage backends
# take on corrupted reads (load_graph never raises) - log + continue,
# never crash the test suite.
module IntegrationCleanup
  # Canonical subdir / file names the tracer writes under a project
  # root: storage cache + per-run reports + coverage results +
  # SimpleCov output + Rails-fixture tmp tree. Specs that test the
  # canonical path set call `scrub_default!(root)`; specs that need
  # a narrower scrub pass paths to `scrub_paths!` directly.
  DEFAULT_SUBDIRS = %w[
    rspec_tracer_cache
    rspec_tracer_coverage
    rspec_tracer_report
    coverage
    tmp
  ].freeze

  # Remove each path with FileUtils.rm_rf. Permission / readonly /
  # transient errors on individual paths are captured and returned
  # as a list of [path, exception] tuples - the caller can assert
  # an empty failure list for strict cleanup or ignore for best-
  # effort. Nil and empty entries are silently skipped so callers
  # can pass `Configuration#cache_path` results without a guard
  # (the tracer initializes those lazily; specs that haven't started
  # the tracer yet may have nil paths).
  def self.scrub_paths!(*paths, logger: nil)
    failures = []
    paths.flatten.each do |path|
      next if path.nil? || path.to_s.empty?

      begin
        FileUtils.rm_rf(path, secure: true)
      rescue StandardError => e
        failures << [path, e]
        logger&.warn("integration_cleanup: failed to scrub #{path.inspect}: #{e.class}: #{e.message}")
      end
    end
    failures
  end

  # Convenience: scrub the DEFAULT_SUBDIRS set under `root`. Returns
  # the same per-path failure list shape as `scrub_paths!`. Use for
  # specs that drive a fixture project end-to-end and want every
  # known tracer footprint cleared.
  def self.scrub_default!(root, logger: nil)
    paths = DEFAULT_SUBDIRS.map { |sub| File.join(root, sub) }
    scrub_paths!(*paths, logger: logger)
  end
end
