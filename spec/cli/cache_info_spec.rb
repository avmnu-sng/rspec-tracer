# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'json'
require 'fileutils'

require 'rspec_tracer/cli/cache_info'

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable
RSpec.describe RSpecTracer::CLI::CacheInfo do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  describe '.run' do
    it 'prints help on -h / --help' do
      %w[-h --help].each do |flag|
        out = StringIO.new
        expect(described_class.run([flag], stdout: out, stderr: stderr)).to eq(0)
        expect(out.string).to include('Usage: rspec-tracer cache:info')
      end
    end

    context 'with a populated cache' do
      before do
        @tmp_dir = Dir.mktmpdir
        run_id = 'run_abc123'
        run_dir = File.join(@tmp_dir, run_id)
        FileUtils.mkdir_p(run_dir)
        File.write(File.join(@tmp_dir, 'last_run.json'),
                   JSON.dump('run_id' => run_id, 'generated_at' => '2026-05-02T17:00:00Z'))
        File.write(File.join(run_dir, 'all_examples.json'),
                   JSON.dump('a' => { 'description' => 'one' }, 'b' => { 'description' => 'two' }))
        allow(RSpecTracer).to receive(:cache_path).and_return(@tmp_dir)
      end

      after { FileUtils.rm_rf(@tmp_dir) if @tmp_dir }

      it 'prints cache_path, size, last_run id, generated_at, and example count' do
        expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('cache_path:')
        expect(stdout.string).to include('size:')
        expect(stdout.string).to include('last_run:   run_abc123')
        expect(stdout.string).to include('generated:  2026-05-02T17:00:00Z')
        expect(stdout.string).to include('examples:   2 tracked')
      end
    end

    context 'with no last_run.json' do
      it 'reports the empty-cache state and exits 0' do
        Dir.mktmpdir do |dir|
          allow(RSpecTracer).to receive(:cache_path).and_return(dir)
          expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
          expect(stdout.string).to include('no last_run.json yet')
        end
      end
    end

    it 'rescues StandardError and returns 1 with a clear error' do
      allow(RSpecTracer).to receive(:cache_path).and_raise(StandardError, 'cache resolve boom')

      expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(1)
      expect(stderr.string).to include('cache:info:')
      expect(stderr.string).to include('boom')
    end
  end

  describe '.format_bytes' do
    it 'returns 0 B for zero or negative input' do
      expect(described_class.format_bytes(0)).to eq('0 B')
      expect(described_class.format_bytes(-1)).to eq('0 B')
    end

    it 'formats bytes / KB / MB / GB with one decimal' do
      expect(described_class.format_bytes(500)).to eq('500.0 B')
      expect(described_class.format_bytes(2_048)).to eq('2.0 KB')
      expect(described_class.format_bytes(5 * 1024 * 1024)).to eq('5.0 MB')
      expect(described_class.format_bytes(3 * 1024 * 1024 * 1024)).to eq('3.0 GB')
    end
  end

  describe '.directory_size' do
    it 'returns 0 for non-existent paths' do
      expect(described_class.directory_size('/nope/does/not/exist')).to eq(0)
    end

    it 'sums file sizes recursively' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'a.txt'), 'x' * 100)
        FileUtils.mkdir_p(File.join(dir, 'sub'))
        File.write(File.join(dir, 'sub', 'b.txt'), 'y' * 200)

        expect(described_class.directory_size(dir)).to eq(300)
      end
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable
