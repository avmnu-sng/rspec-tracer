# frozen_string_literal: true

require 'json'

require 'rspec_tracer/cli/snapshot_helpers'
require 'rspec_tracer/tracker/whole_suite_invalidators'

module RSpecTracer
  # Internal CLI; see {RSpecTracer} for the user-facing surface.
  # @api private
  module CLI
    # `rspec-tracer blast-radius <file> [<file> ...]`: show which
    # examples a change to each given file would re-run on the next
    # rspec invocation. Reads the persisted reverse-dependency map
    # (file -> examples) plus the whole-suite invalidator watch list
    # and the boot set, so whole-suite triggers (Gemfile.lock, boot
    # files) report "re-runs all N examples" instead of under-reporting
    # via a bare reverse-dependency lookup. Reports the file-change
    # trigger only; examples that always re-run for status reasons
    # (failed / flaky / pending / interrupted) are not included.
    # Backend-agnostic: dispatches through
    # {RSpecTracer::Storage::Backend.build} (via
    # {SnapshotHelpers.load_snapshot}) so `storage_backend :sqlite`
    # resolves the latest run from the meta table instead of the
    # JsonBackend-only `last_run.json` file.
    module BlastRadius
      # Internal constant.
      # @api private
      USAGE = 'rspec-tracer blast-radius [--list|--json] <file> [<file> ...]'

      # Statuses whose blast radius is the entire suite (a change to
      # the file invalidates every cached example, not just tracked
      # dependents).
      # @api private
      WHOLE_SUITE_STATUSES = %w[whole_suite_invalidator boot_file].freeze

      # @param args [Array<String>] sub-command args. `--list` / `--json`
      #   flags plus one or more file paths (relative to the project
      #   root or absolute).
      # @param stdout [IO]
      # @param stderr [IO]
      # @return [Integer] exit status (0 = radius printed, including
      #   untracked / zero-dependent files; 1 = no files given, unknown
      #   option, cache missing, or schema mismatch).
      def self.run(args, stdout: $stdout, stderr: $stderr)
        return print_help(stdout) if SnapshotHelpers.help_requested?(args)

        parsed = parse_args(args)
        return unknown_option(parsed[:unknown], stderr) unless parsed[:unknown].nil?
        return no_files(stderr) if parsed[:files].empty?

        execute(parsed, stdout, stderr)
      rescue Errno::EPIPE
        # Downstream pipe (`... | head`, `... | jq`) closed early,
        # which is routine in shell pipelines (the help text promotes
        # them), not a failure. Exit 0 silently.
        0
      rescue StandardError => e
        stderr.puts "blast-radius: #{e.class}: #{e.message}"
        1
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.execute(parsed, stdout, stderr)
        loaded = SnapshotHelpers.load_snapshot(RSpecTracer.cache_path, command: 'blast-radius', stderr: stderr)
        return 1 if loaded.nil?

        snapshot, = loaded
        radii = parsed[:files].map { |file| radius_for(file, snapshot) }
        if parsed[:json]
          stdout.puts JSON.pretty_generate(json_payload(radii, snapshot))
        else
          print_report(stdout, radii, snapshot, list: parsed[:list])
        end
        0
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.parse_args(args)
        parsed = { list: false, json: false, files: [], unknown: nil }
        args.each do |arg|
          case arg
          when '--list' then parsed[:list] = true
          when '--json' then parsed[:json] = true
          when /\A-/ then parsed[:unknown] ||= arg
          else parsed[:files] << arg
          end
        end
        parsed
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.unknown_option(arg, stderr)
        stderr.puts "blast-radius: unknown option #{arg.inspect}"
        stderr.puts "  usage: #{USAGE}"
        1
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.no_files(stderr)
        stderr.puts 'blast-radius: no file paths given'
        stderr.puts "  usage: #{USAGE}"
        1
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_help(stdout)
        stdout.puts <<~HELP
          Usage: #{USAGE}

          Show which examples a change to each given file would re-run on
          the next rspec invocation. Reports the file-change trigger only;
          examples that always re-run for status reasons (failed / flaky /
          pending / interrupted) are not included. Paths may be relative to
          the project root or absolute. Whole-suite invalidators
          (Gemfile.lock, .ruby-version, .rspec-tracer) and boot files
          re-run every example. Backend-aware: works under
          `storage_backend :json` (default) and `storage_backend :sqlite`.
          Requires a prior rspec run.

          Multi-file input composes with git:

            git diff --name-only main | xargs bundle exec rspec-tracer blast-radius

          Options:
            --list    Enumerate affected examples (location + description).
            --json    Emit one machine-readable JSON document to stdout.
        HELP
        0
      end

      # Convert a user-supplied path into the cache's file_name
      # convention (project-relative with a leading `/`, absolute when
      # outside the project root). Computed at command runtime against
      # `RSpecTracer.root`; `SourceFile.file_name` is unsuitable here
      # because its PROJECT_ROOT_REGEX freezes the root at gem-require
      # time, before the CLI loads the project's `.rspec-tracer` config.
      # @api private
      def self.normalize_file_name(path)
        root = RSpecTracer.root
        abs = File.expand_path(path, root)
        return abs unless abs.start_with?("#{root}/")

        "/#{abs[(root.length + 1)..]}"
      end

      # Classify one input file and collect its affected examples.
      # Precedence: whole-suite invalidator watch file, then boot file
      # (boot-set changes OR into whole-suite invalidation), then
      # tracked reverse dependents, then untracked / no-dependents.
      # Note the key conventions: `boot_set` keys are project-relative
      # (no leading slash) while `reverse_dependency` / `all_files`
      # keys carry a leading slash.
      # @api private
      def self.radius_for(path, snapshot)
        file_name = normalize_file_name(path)
        relative = file_name.delete_prefix('/')

        if Tracker::WholeSuiteInvalidators::WATCH_FILES.include?(relative)
          whole_suite_radius(path, file_name, 'whole_suite_invalidator', snapshot)
        elsif (snapshot.boot_set || {}).key?(relative)
          whole_suite_radius(path, file_name, 'boot_file', snapshot)
        else
          dependent_radius(path, file_name, snapshot)
        end
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.whole_suite_radius(path, file_name, status, snapshot)
        ids = (snapshot.all_examples || {}).keys
        { path: path, file_name: file_name, status: status,
          examples: example_entries(ids, snapshot) }
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.dependent_radius(path, file_name, snapshot)
        ids = (snapshot.reverse_dependency || {})[file_name]
        if ids.nil? || ids.empty?
          status = (snapshot.all_files || {}).key?(file_name) ? 'no_dependents' : 'untracked'
          { path: path, file_name: file_name, status: status, examples: [] }
        else
          { path: path, file_name: file_name, status: 'tracked',
            examples: example_entries(ids, snapshot) }
        end
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.example_entries(ids, snapshot)
        all = snapshot.all_examples || {}
        ids.map { |id| example_entry(id.to_s, all[id]) }
          .sort_by { |entry| [entry[:location], entry[:description]] }
      end

      # Enrich one example_id from the persisted all_examples meta.
      # A dangling id (present in reverse_dependency but missing from
      # all_examples, a stale or partially-written cache) degrades to
      # `<unknown>` fields instead of raising.
      # @api private
      def self.example_entry(id, meta)
        meta = {} unless meta.is_a?(::Hash)
        file, line = SnapshotHelpers.example_location(meta)
        {
          example_id: id,
          spec_file: file || '<unknown>',
          location: file.nil? ? '<unknown>' : "#{file}:#{line}",
          description: SnapshotHelpers.example_description(meta) || '<unknown>'
        }
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_report(stdout, radii, snapshot, list:)
        radii.each do |radius|
          stdout.puts summary_line(radius)
          next unless list

          radius[:examples].each do |entry|
            stdout.puts "  #{entry[:location]}  #{entry[:description]}"
          end
        end
        print_total(stdout, radii, snapshot) if radii.size > 1
      end

      # Internal helper for the tracer pipeline.
      # The untracked wording sticks to what the tracer can actually
      # observe: absence of the file from the cache. It must NOT claim
      # the file "never loaded": files consumed outside the hooked
      # surface (spec_helper.rb itself, which executes before coverage
      # tracking starts; reads via unhooked APIs, C extensions, or
      # other threads) load fine yet never appear in the cache. See
      # the soundness model in ARCHITECTURE.md.
      # @api private
      def self.summary_line(radius)
        file_name = radius[:file_name]
        count = radius[:examples].size
        case radius[:status]
        when 'whole_suite_invalidator'
          "#{file_name}: whole-suite invalidator; re-runs all #{count} examples"
        when 'boot_file'
          "#{file_name}: boot file; re-runs all #{count} examples"
        when 'untracked'
          "#{file_name}: not tracked in cache (no recorded dependents: the tracer never " \
          'observed it as an input; see the soundness model in ARCHITECTURE.md)'
        when 'no_dependents'
          "#{file_name}: 0 examples (no tracked dependents)"
        else
          "#{file_name}: #{count} examples across #{spec_file_count(radius[:examples])} spec files"
        end
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_total(stdout, radii, snapshot)
        if radii.any? { |radius| WHOLE_SUITE_STATUSES.include?(radius[:status]) }
          total = (snapshot.all_examples || {}).size
          stdout.puts "total: all #{total} examples (whole-suite invalidator)"
        else
          union = union_entries(radii)
          stdout.puts "total: #{union.size} unique examples across #{spec_file_count(union)} spec files"
        end
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.union_entries(radii)
        radii.flat_map { |radius| radius[:examples] }.uniq { |entry| entry[:example_id] }
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.spec_file_count(entries)
        entries.map { |entry| entry[:spec_file] }.uniq.size
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.json_payload(radii, snapshot)
        union = union_entries(radii)
        {
          'files' => radii.map { |radius| file_json(radius) },
          'total' => {
            'example_count' => union.size,
            'spec_file_count' => spec_file_count(union),
            'whole_suite' => radii.any? { |radius| WHOLE_SUITE_STATUSES.include?(radius[:status]) },
            'all_examples_count' => (snapshot.all_examples || {}).size
          }
        }
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.file_json(radius)
        {
          'path' => radius[:path],
          'file_name' => radius[:file_name],
          'status' => radius[:status],
          'example_count' => radius[:examples].size,
          'spec_file_count' => spec_file_count(radius[:examples]),
          'examples' => radius[:examples].map do |entry|
            {
              'example_id' => entry[:example_id],
              'location' => entry[:location],
              'description' => entry[:description]
            }
          end
        }
      end
    end
  end
end
