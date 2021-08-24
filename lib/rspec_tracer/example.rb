# frozen_string_literal: true

module RSpecTracer
  module Example
    module_function

    def from(example)
      data = {
        example_group: example.example_group.name,
        description: example.description,
        full_description: example.full_description,
        shared_group: example.metadata[:shared_group_inclusion_backtrace]
          .map(&:formatted_inclusion_location)
      }.merge(example_location(example))

      data.merge(example_id: Digest::MD5.hexdigest(data.to_json))
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

    private_class_method :example_location, :example_rerun_location, :location_file_name
  end
end
