# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'yaml'
require 'rspec_tracer/tracker/io_hooks'
require 'rspec_tracer/tracker/io_hooks/yaml'

RSpec.describe RSpecTracer::Tracker::IOHooks::YAMLReads do
  let(:tmp_base) { Dir.mktmpdir }
  let(:root) { File.join(tmp_base, 'project').tap { |p| FileUtils.mkdir_p(p) } }
  let(:bucket) { {} }
  let(:fixture) do
    path = File.join(root, 'config.yml')
    File.write(path, "a: 1\nb: 2\n")
    path
  end

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  around do |example|
    RSpecTracer::Tracker::IOHooks.install(root: root)
    example.run
  ensure
    RSpecTracer::Tracker::IOHooks.uninstall
  end

  describe '#load_file' do
    let(:parsed) do
      RSpecTracer::Tracker::IOHooks.with_bucket(bucket) { YAML.load_file(fixture) }
    end

    it 'records the path' do
      parsed
      expect(bucket).to have_key('data:config.yml')
    end

    it 'returns the parsed YAML via super' do
      expect(parsed).to eq('a' => 1, 'b' => 2)
    end
  end

  describe '#safe_load_file' do
    it 'records the path' do
      RSpecTracer::Tracker::IOHooks.with_bucket(bucket) { YAML.safe_load_file(fixture) }

      expect(bucket).to have_key('data:config.yml')
    end
  end

  describe '#unsafe_load_file' do
    it 'records the path' do
      RSpecTracer::Tracker::IOHooks.with_bucket(bucket) { YAML.unsafe_load_file(fixture) }

      expect(bucket).to have_key('data:config.yml')
    end
  end
end
