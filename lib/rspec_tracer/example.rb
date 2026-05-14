# frozen_string_literal: true

module RSpecTracer
  # Builds the identity-hash payload (`:example_id`-keyed Hash) that
  # RSpec::RunnerHook attaches to every example pre-run.
  #
  # == Identity stability contract
  #
  # `example_id` is the MD5 of a stable subset of the payload:
  # `example_group` (the describe block's *description* string),
  # `description`, `full_description`, `shared_group` (inclusion
  # locations with the trailing line number stripped), and
  # `file_name`. The contract, in one line: *rename = new identity;
  # restructure = same identity.*
  #
  # Identity is PRESERVED when:
  # - blank lines or comments are added/removed around the example
  # - examples are reordered within a describe block (named
  #   examples only - see "Unnamed examples" below)
  # - a sibling describe / example in the same file is renamed
  # - metadata changes (`skip:`, tags, `tracks: { ... }`) - the
  #   spec-file digest still triggers the re-run and status history
  #   is kept
  # - the example body or its hooks (`before`, `let`) are edited -
  #   again, the file digest triggers the re-run
  #
  # Identity CHANGES (one cold "No cache" run) when:
  # - the file is renamed or moved
  # - the `describe` / `it` / shared-example name is changed
  # - the example moves to a different describe block
  #
  # == Unnamed examples (`it { }`, `specify { }`, `example { }`)
  #
  # An example with no description string has no stable name to hash,
  # and identity must be computed pre-run (for the filter decision),
  # before RSpec generates a matcher-derived description. The only
  # line-independent signal RSpec exposes pre-run is position, so an
  # unnamed example's identity is derived from its ordinal among the
  # *unnamed* examples of its group. (RSpec's `description` for an
  # unnamed example is the line-bearing `"example at <path>:<line>"`
  # fallback, which would otherwise leak the line number straight
  # back into the digest - issue #210.)
  #
  # For unnamed examples the contract above is amended: identity is
  # still PRESERVED across blank-line / comment edits, sibling
  # renames, and adding or removing *named* siblings - but it CHANGES
  # when the unnamed examples are reordered, or one is inserted or
  # removed ahead of it. Give an example an explicit description
  # (`it 'does X' do`) for a fully reorder-stable identity.
  #
  # `line_number` / `rerun_file_name` / `rerun_line_number` stay in
  # the returned Hash for the reporter + `explain` location columns,
  # but are DELIBERATELY EXCLUDED from the digest - a no-op edit that
  # shifts line numbers must not invalidate the cache. `example_group`
  # uses `example_group.description` (the user's string) rather than
  # `example_group.name`: RSpec's generated class name carries a
  # load-order-dependent `_2` / `_3` suffix when two files share a
  # describe name, which would otherwise flip the id across runs.
  #
  # Helpers are `def self.x` + `private_class_method` so mutant
  # attributes mutations through the singleton call path.
  module Example
    # Builds the identity payload for one RSpec example. The MD5 is
    # taken over the stability-contract subset (see `digest_identity`
    # for the named-vs-unnamed split); `line_number` / `rerun_*` ride
    # along in the returned Hash for the reporters but never enter the
    # digest. See the module comment for the full stability contract.
    # @api private
    def self.from(example)
      location = example_location(example)
      identity = {
        example_group: example.example_group.description,
        description: example.description,
        full_description: example.full_description,
        shared_group: example.metadata[:shared_group_inclusion_backtrace]
          .map { |frame| frame.formatted_inclusion_location.sub(/:\d+\z/, '') },
        file_name: location[:file_name]
      }

      identity
        .merge(location)
        .merge(example_id: Digest::MD5.hexdigest(digest_identity(example, identity).to_json))
    end

    # The Hash actually fed to the MD5. For a named example this is
    # `identity` unchanged - byte-identical to the pre-#210 digest.
    # For an unnamed example (`it { }` / `specify { }` / `example { }`)
    # RSpec's `description` is the line-bearing location fallback
    # `"example at <path>:<line>"`, so `description` is swapped for a
    # line-independent positional discriminator before hashing. The
    # returned/stored payload still carries RSpec's `description` /
    # `full_description` untouched - only the digest input differs.
    # @api private
    def self.digest_identity(example, identity)
      return identity unless unnamed?(example)

      identity.merge(description: unnamed_description(example))
    end

    # True when the example has no explicit description string. RSpec's
    # raw `metadata[:description]` is `""` for `it { }` / `specify { }`
    # / `example { }`; the `description` *method* would instead return
    # the line-bearing `"example at <path>:<line>"` fallback, so the
    # raw metadata value is what cleanly tells named from unnamed.
    # @api private
    def self.unnamed?(example)
      example.metadata[:description].to_s.strip.empty?
    end

    # Line-independent identity discriminator for an unnamed example:
    # its 0-based ordinal among the *unnamed* examples of its group.
    # Stable across blank-line / comment edits and across adding or
    # renaming *named* siblings; changes only when the unnamed examples
    # are reordered or one is inserted / removed ahead of it (the
    # documented carve-out - see the module comment). Closes the
    # remaining #196 gap reported in #210.
    # @api private
    def self.unnamed_description(example)
      unnamed_siblings = example.example_group.examples.select { |sibling| unnamed?(sibling) }

      "example at unnamed index #{unnamed_siblings.index(example)}"
    end

    # Internal helper for the tracer pipeline.
    # @api private
    def self.example_location(example)
      metadata = example.metadata

      location = {
        file_name: location_file_name(metadata[:file_path]),
        line_number: metadata[:line_number]
      }

      if metadata[:file_path] == metadata[:rerun_file_path]
        return location.merge(
          rerun_file_name: location[:file_name],
          rerun_line_number: location[:line_number]
        )
      end

      location.merge(example_rerun_location(example.example_group.parent_groups))
    end

    # Internal helper for the tracer pipeline.
    # @api private
    def self.example_rerun_location(example_groups)
      example_groups.each do |example_group|
        metadata = example_group.metadata

        next unless metadata[:file_path] == metadata[:rerun_file_path]

        return {
          rerun_file_name: location_file_name(metadata[:file_path]),
          rerun_line_number: metadata[:line_number]
        }
      end
    end

    # Internal helper for the tracer pipeline.
    # @api private
    def self.location_file_name(rspec_file_name)
      file_path = RSpecTracer::SourceFile.file_path(rspec_file_name)

      RSpecTracer::SourceFile.file_name(file_path)
    end

    private_class_method :digest_identity, :unnamed?, :unnamed_description,
                         :example_location, :example_rerun_location, :location_file_name
  end
end
