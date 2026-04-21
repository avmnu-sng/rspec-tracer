# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'rspec_tracer/tracker/io_hooks'
require 'rspec_tracer/tracker/io_hooks/io'

RSpec.describe RSpecTracer::Tracker::IOHooks::IOReads do
  let(:tmp_base) { Dir.mktmpdir }
  let(:root) { File.join(tmp_base, 'project').tap { |p| FileUtils.mkdir_p(p) } }
  let(:bucket) { {} }
  let(:fixture) do
    path = File.join(root, 'fixture.yml')
    File.write(path, "a: 1\n")
    path
  end

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  around do |example|
    RSpecTracer::Tracker::IOHooks.install(root: root)
    example.run
  ensure
    RSpecTracer::Tracker::IOHooks.uninstall
  end

  describe '#read' do
    # IO.read is explicitly what's under test - File.read is the
    # rubocop recommendation, not applicable here.
    # rubocop:disable Security/IoMethods
    let(:contents) do
      RSpecTracer::Tracker::IOHooks.with_bucket(bucket) { IO.read(fixture) }
    end
    # rubocop:enable Security/IoMethods

    it 'records the path' do
      contents
      expect(bucket).to have_key('data:fixture.yml')
    end

    it 'returns the file contents via super' do
      expect(contents).to eq("a: 1\n")
    end
  end
end
