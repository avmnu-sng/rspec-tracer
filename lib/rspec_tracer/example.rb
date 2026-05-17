# frozen_string_literal: true

module RSpecTracer
  module Example
    module_function

    # Identity-keyed cache of `<example_group> => Array<unnamed sibling>`
    # populated lazily by `unnamed_description`. A group with N unnamed
    # examples computes the sibling list once per group rather than N
    # times. Memory is bounded by the live group set, which RSpec
    # retains for the run anyway.
    @unnamed_siblings_cache = {}.compare_by_identity

    def from(example)
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
    # `identity` unchanged. For an unnamed example (`it { }` /
    # `specify { }` / `example { }`) RSpec's `description` is the
    # line-bearing `"example at <path>:<line>"` fallback, so
    # `description` is swapped for a line-independent positional
    # discriminator before hashing. The returned/stored payload still
    # carries RSpec's `description` / `full_description` untouched —
    # only the digest input differs.
    def digest_identity(example, identity)
      return identity unless unnamed?(example)

      identity.merge(description: unnamed_description(example))
    end

    # RSpec's raw `metadata[:description]` is `""` for `it { }` /
    # `specify { }` / `example { }`; the `description` *method* would
    # instead return the line-bearing `"example at <path>:<line>"`
    # fallback, so the raw metadata value is what cleanly tells named
    # from unnamed.
    def unnamed?(example)
      example.metadata[:description].to_s.strip.empty?
    end

    # 0-based ordinal of the example among the *unnamed* examples of
    # its group. Stable across blank-line / comment edits and across
    # adding or renaming *named* siblings; changes only when the
    # unnamed examples are reordered or one is inserted / removed
    # ahead of it. The Ruby-inspect-style `#<...>` form makes spoofing
    # by a real user description implausible.
    def unnamed_description(example)
      group = example.example_group
      unnamed_siblings = @unnamed_siblings_cache[group] ||=
        group.examples.select { |sibling| unnamed?(sibling) }

      "#<rspec-tracer unnamed example #{unnamed_siblings.index(example)}>"
    end

    def example_location(example)
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

    def example_rerun_location(example_groups)
      example_groups.each do |example_group|
        metadata = example_group.metadata

        next unless metadata[:file_path] == metadata[:rerun_file_path]

        return {
          rerun_file_name: location_file_name(metadata[:file_path]),
          rerun_line_number: metadata[:line_number]
        }
      end
    end

    def location_file_name(rspec_file_name)
      file_path = RSpecTracer::SourceFile.file_path(rspec_file_name)

      RSpecTracer::SourceFile.file_name(file_path)
    end

    private_class_method :digest_identity, :unnamed?, :unnamed_description,
                         :example_location, :example_rerun_location, :location_file_name
  end
end
