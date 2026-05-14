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
  # - examples are reordered within a describe block
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
    # taken over `identity` only (the stability-contract subset);
    # `line_number` / `rerun_*` ride along in the returned Hash for
    # the reporters but never enter the digest. See the module
    # comment for the full stability contract.
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
        .merge(example_id: Digest::MD5.hexdigest(identity.to_json))
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

    private_class_method :example_location, :example_rerun_location, :location_file_name
  end
end
