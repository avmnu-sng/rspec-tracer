# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'rspec_tracer/tracker/io_hooks'
require 'rspec_tracer/tracker/io_hooks/file'

RSpec.describe RSpecTracer::Tracker::IOHooks::FileReads do
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
    let(:contents) do
      RSpecTracer::Tracker::IOHooks.with_bucket(bucket) { File.read(fixture) }
    end

    it 'records the path' do
      contents
      expect(bucket).to have_key('data:fixture.yml')
    end

    it 'returns the file contents via super' do
      expect(contents).to eq("a: 1\n")
    end
  end

  describe '#binread' do
    it 'records the path' do
      RSpecTracer::Tracker::IOHooks.with_bucket(bucket) { File.binread(fixture) }

      expect(bucket).to have_key('data:fixture.yml')
    end
  end

  describe '#readlines' do
    it 'records the path' do
      RSpecTracer::Tracker::IOHooks.with_bucket(bucket) { File.readlines(fixture) }

      expect(bucket).to have_key('data:fixture.yml')
    end
  end

  describe '#open' do
    it 'records the path (no-block form)' do
      RSpecTracer::Tracker::IOHooks.with_bucket(bucket) do
        File.open(fixture, 'r') { :noop } # block form avoids the FD-leak cop
      end

      expect(bucket).to have_key('data:fixture.yml')
    end

    describe '(block form)' do
      let(:yielded) do
        captured = nil
        RSpecTracer::Tracker::IOHooks.with_bucket(bucket) do
          File.open(fixture, 'r') { |f| captured = f.read }
        end
        captured
      end

      it 'records the path' do
        yielded
        expect(bucket).to have_key('data:fixture.yml')
      end

      it 'yields the handle to the block' do
        expect(yielded).to eq("a: 1\n")
      end
    end
  end
end
