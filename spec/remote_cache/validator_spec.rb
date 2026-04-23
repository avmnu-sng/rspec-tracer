# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'

require 'rspec_tracer/remote_cache/validator'
require 'rspec_tracer/storage/schema'

# rubocop:disable RSpec/ExampleLength
RSpec.describe RSpecTracer::RemoteCache::Validator do
  let(:current_schema) { RSpecTracer::Storage::Schema::CURRENT }

  describe '.valid?' do
    it 'returns true for a hash with the current schema_version' do
      expect(described_class.valid?('schema_version' => current_schema)).to be(true)
    end

    it 'returns false for a hash with a mismatched schema_version' do
      expect(described_class.valid?('schema_version' => current_schema + 1)).to be(false)
    end

    it 'returns false for a hash without schema_version' do
      expect(described_class.valid?('run_id' => 'abc')).to be(false)
    end

    it 'returns false for a hash with nil schema_version' do
      expect(described_class.valid?('schema_version' => nil)).to be(false)
    end

    it 'returns false for nil input' do
      expect(described_class.valid?(nil)).to be(false)
    end

    it 'returns false for a String input' do
      expect(described_class.valid?('not a hash')).to be(false)
    end

    it 'returns false for an Array input' do
      expect(described_class.valid?([1, 2, 3])).to be(false)
    end
  end

  describe '.valid_file?' do
    it 'returns true when the file contains a current-schema manifest' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'last_run.json')
        File.write(path, JSON.pretty_generate('schema_version' => current_schema, 'run_id' => 'abc'))

        expect(described_class.valid_file?(path)).to be(true)
      end
    end

    it 'returns false when the file is missing' do
      expect(described_class.valid_file?('/nonexistent/path.json')).to be(false)
    end

    it 'returns false when the file contains a mismatched schema' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'last_run.json')
        File.write(path, JSON.pretty_generate('schema_version' => 999))

        expect(described_class.valid_file?(path)).to be(false)
      end
    end

    it 'returns false when the file contains malformed JSON' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'last_run.json')
        File.write(path, '{not valid json')

        expect(described_class.valid_file?(path)).to be(false)
      end
    end

    it 'returns false when the file contains a JSON array (not a hash)' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'last_run.json')
        File.write(path, '[1, 2, 3]')

        expect(described_class.valid_file?(path)).to be(false)
      end
    end

    it 'returns false when the file exists but is unreadable' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'last_run.json')
        File.write(path, JSON.pretty_generate('schema_version' => current_schema))
        File.chmod(0, path)

        expect(described_class.valid_file?(path)).to be(false)
      ensure
        File.chmod(0o644, path) if path && File.exist?(path)
      end
    end
  end
end
# rubocop:enable RSpec/ExampleLength
