# frozen_string_literal: true

module RSpecTracer
  module SourceFile
    PROJECT_ROOT_REGEX = Regexp.new("^#{Regexp.escape(RSpecTracer.root)}").freeze

    module_function

    def from_path(file_path)
      return unless File.file?(file_path)

      {
        file_path: file_path,
        file_name: file_name(file_path),
        digest: Digest::MD5.hexdigest(File.read(file_path))
      }
    end

    def from_name(file_name)
      from_path(file_path(file_name))
    end

    def file_name(file_path)
      file_path.sub(PROJECT_ROOT_REGEX, '')
    end

    def file_path(file_name)
      # return if an absolute path, eg included examples above working directory
      return file_name if File.file?(file_name)
      # otherwise append root, to get an absolute path.
      File.expand_path(file_name.sub(%r{^/}, ''), RSpecTracer.root)
    end
  end
end
