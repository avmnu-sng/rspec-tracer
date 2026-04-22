# frozen_string_literal: true

require 'set'

module RSpecTracer
  module Storage
    # Value object returned by `Backend#load_graph` and accepted by
    # `Backend#save_graph`. Bundles every collection that 1.x's
    # report_writer persists plus the schema_version + run_id envelope
    # so a full cache can be reconstructed in one trip.
    #
    # The field layout mirrors 1.x's on-disk contract (see
    # `JsonBackend::FILENAMES`); every field round-trips through
    # `to_h` / `from_h` so the backend can serialize without reaching
    # into struct internals.
    #
    # `examples_coverage` may be `nil` when a caller explicitly loads
    # the cheap header only (M3.6 will wire that path). The default
    # load is eager - `nil` vs `{}` distinguishes "not yet loaded"
    # from "loaded and empty."
    #
    # Methods are defined on the reopened class body (not inside the
    # Struct.new block) so mutant can introspect them - same pattern
    # as Tracker::Input.
    #
    # M3.7 adds `boot_set` - Hash[relative_path => sha256_hex] of every
    # project file loaded before any example runs (spec_helper
    # requires, gem boot, eager autoload). Backs the constants-
    # blind-spot fix: the M3.6 caller compares this against the
    # previous run's boot_set and ORs any mismatch with
    # WholeSuiteInvalidators when computing the whole_suite_invalidated
    # bool. Per-example loaded-set attribution folds into `dependency`
    # via the existing graph registration path - no separate field.
    #
    # M4.3 adds `wsi_snapshot` - Hash[watch_name => sha256_hex] produced
    # by `WholeSuiteInvalidators#digest_snapshot`. Without it, a warm
    # run can't tell whether Gemfile.lock / .ruby-version / .rspec-tracer
    # (or the tracer gem identity) changed since the previous run, and
    # the engine falls back to "first run = invalidate everything" on
    # every warm run. The field is optional in the JSON layout so caches
    # saved before M4.3 continue to load (missing wsi.json coerces to
    # `{}`, which compares unequal and triggers one cold re-run - safe
    # fallback, same cost as any other cache miss).
    #
    # M5.2 adds `env_snapshot` - Hash[env_name => md5_hex] produced by
    # `Tracker::EnvSnapshot#digest_snapshot`. Covers env-var values
    # declared via the per-example `tracks: { env: ... }` DSL.
    # Without it, a warm run can't tell whether an env-gated example
    # needs to re-run when the env changes. Same optional-in-JSON
    # treatment as wsi_snapshot: missing file coerces to `{}`, no
    # schema_version bump, one cold re-run on upgrade.
    Snapshot = Struct.new(
      :schema_version,
      :run_id,
      :all_examples,
      :duplicate_examples,
      :interrupted_examples,
      :flaky_examples,
      :failed_examples,
      :pending_examples,
      :skipped_examples,
      :all_files,
      :dependency,
      :reverse_dependency,
      :examples_coverage,
      :boot_set,
      :wsi_snapshot,
      :env_snapshot,
      keyword_init: true
    )

    class Snapshot
      # Defaults every collection to its 1.x starting shape: Hash for
      # keyed collections, Set for example-id lists. Keeps spec
      # construction terse and prevents accidental nil-deref when a
      # save is composed incrementally.
      def self.empty(schema_version:, run_id:)
        new(
          schema_version: schema_version,
          run_id: run_id,
          all_examples: {},
          duplicate_examples: {},
          interrupted_examples: Set.new,
          flaky_examples: Set.new,
          failed_examples: Set.new,
          pending_examples: Set.new,
          skipped_examples: Set.new,
          all_files: {},
          dependency: {},
          reverse_dependency: {},
          examples_coverage: {},
          boot_set: {},
          wsi_snapshot: {},
          env_snapshot: {}
        )
      end
    end
  end
end
