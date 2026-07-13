# frozen_string_literal: true

require 'rspec_tracer/cli/snapshot_helpers'

module RSpecTracer
  # Internal CLI; see {RSpecTracer} for the user-facing surface.
  # @api private
  module CLI
    # `rspec-tracer explain <example>`: show why a given example is
    # scheduled to run or skip on the next rspec invocation. Backend-
    # agnostic: dispatches through {RSpecTracer::Storage::Backend.build}
    # (via {SnapshotHelpers.load_snapshot}) so `storage_backend :sqlite`
    # resolves the latest run from the meta table instead of the
    # JsonBackend-only `last_run.json` file.
    module Explain
      # @param args [Array<String>] sub-command args. First positional
      #   arg is the example_id (or substring) to explain. `--not-run`
      #   flips the output to the skip-side view: why the example was
      #   NOT run last time, and what would make it run next time.
      # @param stdout [IO]
      # @param stderr [IO]
      # @return [Integer] exit status (0 = explanation printed,
      #   1 = example not found / cache missing).
      def self.run(args, stdout: $stdout, stderr: $stderr)
        args = args.dup
        not_run = !args.delete('--not-run').nil?
        return print_help(stdout) if SnapshotHelpers.help_requested?(args)

        loaded = SnapshotHelpers.load_snapshot(RSpecTracer.cache_path, command: 'explain', stderr: stderr)
        return 1 if loaded.nil?

        snapshot, backend = loaded
        match = find_example(snapshot.all_examples, args.first)
        return no_match(args.first, snapshot.all_examples, stderr) if match.nil?

        if not_run
          print_not_run_explanation(stdout, match, snapshot, backend)
        else
          print_explanation(stdout, match, snapshot)
        end
        0
      rescue Errno::EPIPE
        # Downstream pipe (`... | head`) closed early, which is routine
        # in shell pipelines, not a failure. Exit 0 silently.
        0
      rescue StandardError => e
        stderr.puts "explain: #{e.class}: #{e.message}"
        1
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.no_match(query, all_examples, stderr)
        stderr.puts "explain: no example matching #{query.inspect}"
        stderr.puts "  cache has #{all_examples.size} examples; pass an example_id or substring of description"
        1
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_help(stdout)
        stdout.puts <<~HELP
          Usage: rspec-tracer explain [--not-run] <example_id_or_substring>

          Show why an example is scheduled to run or skip. Matches against
          example_id exactly first, then falls back to a substring match
          on the example's full_description. Backend-aware: works under
          `storage_backend :json` (default) and `storage_backend :sqlite`.
          Requires a prior rspec run.

          --not-run flips to the skip-side view: whether the example was
          skipped on the last run (and why no run trigger fired), its last
          recorded status, and what would make it run on the next rspec
          invocation. The cache keeps only the most recent snapshot, so
          "last status" reflects the last run, not a run history.
        HELP
        0
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.find_example(all_examples, query)
        return all_examples[query] if all_examples.key?(query)

        all_examples.find do |id, meta|
          meta = {} unless meta.is_a?(::Hash)
          desc = SnapshotHelpers.example_description(meta) || ''
          id.include?(query) || desc.include?(query)
        end&.last
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_explanation(stdout, meta, snapshot)
        meta = {} unless meta.is_a?(::Hash)
        id = SnapshotHelpers.fetch_meta(meta, 'example_id', 'id')
        format_lines(meta, skipped: skipped?(id, snapshot)).each { |line| stdout.puts line }
        print_dependency_summary(stdout, meta, snapshot)
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.format_lines(meta, skipped: false)
        id = SnapshotHelpers.fetch_meta(meta, 'example_id', 'id') || '<unknown>'
        file, line = SnapshotHelpers.example_location(meta)
        status = last_status(meta)
        [
          "id:           #{id}",
          "description:  #{SnapshotHelpers.example_description(meta)}",
          "location:     #{file}:#{line}",
          "last status:  #{status}",
          "run reason:   #{run_reason_field(meta, skipped)}"
        ]
      end

      # The run-side `run reason:` value. For an example the filter
      # SKIPPED on the last run, the persisted run_reason is the
      # carry-forward reason seeded from an earlier snapshot: it says
      # why the example ran back then, not why it is in its current
      # state. Printing it bare would misreport a skipped example as
      # having a current run trigger, so flag it and point at the
      # `--not-run` skip-side view instead.
      # @api private
      def self.run_reason_field(meta, skipped)
        reason = SnapshotHelpers.fetch_meta(meta, 'run_reason') || '<not recorded>'
        return reason unless skipped

        "#{reason} (carried forward from an earlier run; " \
          'this example was SKIPPED last run; use --not-run for the skip-side view)'
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.last_status(meta)
        SnapshotHelpers.dig_meta(meta, 'execution_result', 'status') ||
          SnapshotHelpers.fetch_meta(meta, 'status') || 'unknown'
      end

      # The `--not-run` view. Deliberately does NOT print the
      # `run reason:` field from all_examples meta: for a skipped
      # example that field is the carry-forward PRIOR-run reason
      # (seeded from the previous snapshot), so echoing it here would
      # misreport why the example did not run. Everything below is
      # derived from the per-run membership sets instead
      # (skipped_examples / filtered_examples / the status id-sets).
      def self.print_not_run_explanation(stdout, meta, snapshot, backend)
        meta = {} unless meta.is_a?(::Hash)
        id = SnapshotHelpers.fetch_meta(meta, 'example_id', 'id') || '<unknown>'
        filter_persisted = SnapshotHelpers.filter_decisions_persisted?(backend)
        print_not_run_header(stdout, meta, id)
        stdout.puts last_run_line(id, snapshot, filter_persisted: filter_persisted)
        not_run_detail_lines(id, snapshot).each { |detail| stdout.puts detail }
        stdout.puts "last status:  #{last_status(meta)} (most recent snapshot; this cache keeps only the last run)"
        stdout.puts "next run:     #{next_run_line(id, snapshot)}"
        print_dependency_summary(stdout, meta, snapshot)
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_not_run_header(stdout, meta, id)
        file, line = SnapshotHelpers.example_location(meta)
        stdout.puts "id:           #{id}"
        stdout.puts "description:  #{SnapshotHelpers.example_description(meta)}"
        stdout.puts "location:     #{file}:#{line}"
      end

      # Detail lines printed under `last run:`: the itemized skip
      # derivation for a skipped id, a run-side hint for an id that
      # actually ran, nothing for the no-decision fallbacks.
      # @return [Array<String>]
      def self.not_run_detail_lines(id, snapshot)
        return skip_reason_lines(id, snapshot) if skipped?(id, snapshot)

        if ran_reason(id, snapshot)
          return ["  it was not skipped; run 'rspec-tracer explain #{id}' for the run-side view"]
        end

        []
      end

      # One `last run:` line for the `--not-run` view, derived from
      # per-run membership: skipped_examples (the filter skipped it),
      # filtered_examples (it ran, with the recorded reason), or
      # neither. The neither case splits on `filter_persisted`: a
      # backend that persists filter decisions (json) with an empty
      # decision set means the last run recorded no decision for this
      # id (a cold run persists empty sets by design, and an id absent
      # from the last run has no entry either); only a
      # non-persisting backend (sqlite) earns the storage-backend
      # wording.
      # @return [String]
      def self.last_run_line(id, snapshot, filter_persisted:)
        return 'last run:     skipped (cache hit)' if skipped?(id, snapshot)

        reason = ran_reason(id, snapshot)
        return "last run:     ran (#{reason})" if reason
        return 'last run:     <not recorded by this storage backend>' unless filter_persisted

        'last run:     no filter decision recorded (cold run, or this example was not part of it)'
      end

      # Itemized derivation of WHY the filter skipped the example.
      # Sound because a skip logically implies every trigger in the
      # engine's precedence chain declined: no whole-suite invalidator
      # fired, no boot file changed (the engine ORs the boot-set check
      # into whole-suite invalidation), the example carried no
      # always-re-run status, none of its tracked dependency files
      # changed, and its tracked environment snapshot was unchanged.
      # @return [Array<String>]
      def self.skip_reason_lines(id, snapshot)
        deps = Array((snapshot.dependency || {})[id])
        [
          'skip reason:  no run trigger fired last run:',
          '  - whole-suite invalidators (Gemfile.lock, .ruby-version, .rspec-tracer, gem version): unchanged',
          '  - boot set: no boot file changed',
          '  - prior status: not failed / flaky / pending / interrupted',
          "  - dependency files: #{deps.size} tracked, none changed",
          '  - environment snapshot: unchanged for this example'
        ]
      end

      # Prediction line for the NEXT run, from the persisted status
      # sets (the inputs to the next run's always-re-run triggers).
      # @return [String]
      def self.next_run_line(id, snapshot)
        reason = always_rerun_reason(id, snapshot)
        return "will re-run regardless (#{reason} last run)" if reason

        'runs only if a dependency, whole-suite invalidator, boot file, or tracked env var changes'
      end

      # First always-re-run status the id carries, in the filter's
      # precedence order (interrupted > flaky > failed > pending), or
      # nil when the example has no status-based re-run trigger.
      # @return [String, nil]
      def self.always_rerun_reason(id, snapshot)
        return 'interrupted' if in_id_set?(snapshot.interrupted_examples, id)
        return 'flaky' if in_id_set?(snapshot.flaky_examples, id)
        return 'failed' if in_id_set?(snapshot.failed_examples, id)
        return 'pending' if in_id_set?(snapshot.pending_examples, id)

        nil
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.skipped?(id, snapshot)
        in_id_set?(snapshot.skipped_examples, id)
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.ran_reason(id, snapshot)
        SnapshotHelpers.fetch_meta(snapshot.filtered_examples || {}, id)
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.in_id_set?(id_set, id)
        (id_set || []).include?(id)
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_dependency_summary(stdout, meta, snapshot)
        id = SnapshotHelpers.fetch_meta(meta, 'example_id', 'id')
        deps = snapshot.dependency || {}
        files = Array(deps[id])
        stdout.puts "dependencies: #{files.size} files tracked"
        files.first(10).each { |f| stdout.puts "  - #{f}" }
        stdout.puts "  ... (#{files.size - 10} more)" if files.size > 10
      end
    end
  end
end
