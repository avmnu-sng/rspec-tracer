# frozen_string_literal: true

module RSpecTracer
  # Path manipulation helpers used by Example.location_file_name.
  # Post-coverage-stack retirement, the only caller is example.rb
  # (the legacy CoverageReporter that previously used these is gone).
  #
  # All methods declared `def self.x` per
  # feedback_mutation_friendly_modules so mutant observes mutations
  # through the singleton call path.
  module SourceFile
    # Internal constant.
    # @api private
    PROJECT_ROOT_REGEX = Regexp.new("^#{Regexp.escape(RSpecTracer.root)}").freeze

    # Internal helper for the tracer pipeline.
    # @api private
    def self.from_path(file_path)
      return unless File.file?(file_path)

      {
        file_path: file_path,
        file_name: file_name(file_path),
        digest: Digest::MD5.hexdigest(File.binread(file_path))
      }
    end

    # Internal helper for the tracer pipeline.
    # @api private
    def self.from_name(file_name)
      from_path(file_path(file_name))
    end

    # Internal helper for the tracer pipeline.
    # @api private
    def self.file_name(file_path)
      file_path.sub(PROJECT_ROOT_REGEX, '')
    end

    # Internal helper for the tracer pipeline.
    # @api private
    def self.file_path(file_name)
      return file_name if absolute_external_file?(file_name)

      File.expand_path(file_name.sub(%r{^/}, ''), RSpecTracer.root)
    end

    # Internal helper for the tracer pipeline.
    # @api private
    def self.absolute_external_file?(file_name)
      file_name.start_with?('/') &&
        !file_name.start_with?(RSpecTracer.root) &&
        File.file?(file_name)
    end
  end
end
