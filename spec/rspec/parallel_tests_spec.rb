# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tmpdir'

require 'rspec_tracer/rspec/parallel_tests'

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/VerifiedDoubles
# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/StubbedMock, RSpec/MessageSpies
RSpec.describe RSpecTracer::RSpec::ParallelTests do
  let(:tmp_base)    { Dir.mktmpdir }
  let(:lock_file)   { File.join(tmp_base, 'rspec_tracer.lock') }
  let(:cache_path)  { File.join(tmp_base, 'rspec_tracer_cache', 'parallel_tests_1') }
  let(:report_path) { File.join(tmp_base, 'rspec_tracer_report', 'parallel_tests_1') }
  let(:coverage_path) { File.join(tmp_base, 'rspec_tracer_coverage', 'parallel_tests_1') }
  let(:logger) { spy('Logger') }

  # ENV scoping: snapshot + restore the three env vars this module reads
  # so mutations inside an example cannot leak to other specs (either in
  # the same file or across the suite). `around` guarantees the restore
  # runs even on example failure or raised exceptions.
  around do |example|
    original_env = ENV.to_hash.slice('TEST_ENV_NUMBER', 'PARALLEL_TEST_GROUPS', 'RSPEC_TRACER_VERBOSE')
    %w[TEST_ENV_NUMBER PARALLEL_TEST_GROUPS RSPEC_TRACER_VERBOSE].each { |k| ENV.delete(k) }

    example.run
  ensure
    %w[TEST_ENV_NUMBER PARALLEL_TEST_GROUPS RSPEC_TRACER_VERBOSE].each { |k| ENV.delete(k) }
    original_env.each { |k, v| ENV[k] = v }
  end

  before do
    allow(RSpecTracer).to receive_messages(lock_file: lock_file, cache_path: cache_path,
                                           report_path: report_path, coverage_path: coverage_path,
                                           logger: logger, simplecov?: false)
    [cache_path, report_path, coverage_path].each { |p| FileUtils.mkdir_p(File.dirname(p)) }
  end

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  describe '.active?' do
    it 'returns false when neither env var is set' do
      expect(described_class.active?).to be(false)
    end

    it 'returns false when only TEST_ENV_NUMBER is set' do
      ENV['TEST_ENV_NUMBER'] = '1'
      expect(described_class.active?).to be(false)
    end

    it 'returns false when only PARALLEL_TEST_GROUPS is set' do
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      expect(described_class.active?).to be(false)
    end

    it 'returns true when both env vars are set' do
      ENV['TEST_ENV_NUMBER'] = '1'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      expect(described_class.active?).to be(true)
    end
  end

  describe '.narrator?' do
    it 'is true when parallel_tests is not active (single process is its own narrator)' do
      expect(described_class.narrator?).to be(true)
    end

    it 'is true when TEST_ENV_NUMBER is empty string under parallel_tests' do
      ENV['TEST_ENV_NUMBER'] = ''
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      expect(described_class.narrator?).to be(true)
    end

    it 'is true for the first worker (TEST_ENV_NUMBER == 1)' do
      ENV['TEST_ENV_NUMBER'] = '1'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      expect(described_class.narrator?).to be(true)
    end

    it 'is false for non-first workers' do
      ENV['TEST_ENV_NUMBER'] = '2'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      expect(described_class.narrator?).to be(false)
    end
  end

  describe '.verbose?' do
    it 'is false by default' do
      expect(described_class.verbose?).to be(false)
    end

    it 'is true when RSPEC_TRACER_VERBOSE=true' do
      ENV['RSPEC_TRACER_VERBOSE'] = 'true'
      expect(described_class.verbose?).to be(true)
    end
  end

  describe '.log_rollups?' do
    it 'is true when narrator? is true' do
      ENV['TEST_ENV_NUMBER'] = '1'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      expect(described_class.log_rollups?).to be(true)
    end

    it 'is false for a non-narrator worker without verbose' do
      ENV['TEST_ENV_NUMBER'] = '2'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      expect(described_class.log_rollups?).to be(false)
    end

    it 'is true for a non-narrator worker when verbose is on' do
      ENV['TEST_ENV_NUMBER'] = '2'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      ENV['RSPEC_TRACER_VERBOSE'] = 'true'
      expect(described_class.log_rollups?).to be(true)
    end
  end

  describe '.setup!' do
    before do
      ENV['TEST_ENV_NUMBER'] = '3'
      ENV['PARALLEL_TEST_GROUPS'] = '4'
      stub_const('ParallelTests', Module.new)
    end

    it 'returns false when parallel_tests is inactive' do
      ENV.delete('TEST_ENV_NUMBER')
      ENV.delete('PARALLEL_TEST_GROUPS')
      expect(described_class.setup!).to be(false)
    end

    it 'writes the TEST_ENV_NUMBER into the lock file and returns true' do
      expect(described_class.setup!).to be(true)
      expect(File.read(lock_file).to_i).to eq(3)
    end

    it 'keeps the max across concurrent writers (a prior higher value is preserved)' do
      File.write(lock_file, "7\n")

      described_class.setup!

      expect(File.read(lock_file).to_i).to eq(7)
    end

    it 'replaces a lower prior value with the current TEST_ENV_NUMBER' do
      File.write(lock_file, "1\n")

      described_class.setup!

      expect(File.read(lock_file).to_i).to eq(3)
    end

    it 'returns false + logs an error when parallel_tests gem is missing' do
      hide_const('ParallelTests')
      allow(described_class).to receive(:require).with('parallel_tests').and_raise(LoadError, 'no gem')

      expect(described_class.setup!).to be(false)
      expect(logger).to have_received(:error).with(/Failed to load parallel_tests/)
    end
  end

  describe '.last_process?' do
    before { ENV['PARALLEL_TEST_GROUPS'] = '4' }

    it 'is false when parallel_tests is inactive' do
      ENV.delete('PARALLEL_TEST_GROUPS')
      expect(described_class.last_process?).to be(false)
    end

    it 'is false when the parallel_tests gem is not loaded' do
      ENV['TEST_ENV_NUMBER'] = ''
      hide_const('ParallelTests')

      expect(described_class.last_process?).to be(false)
    end

    it 'is true for the first worker (TEST_ENV_NUMBER empty)' do
      ENV['TEST_ENV_NUMBER'] = ''
      require 'parallel_tests'

      expect(described_class.last_process?).to be(true)
    end

    it 'is true for the first worker (TEST_ENV_NUMBER == "1")' do
      ENV['TEST_ENV_NUMBER'] = '1'
      require 'parallel_tests'

      expect(described_class.last_process?).to be(true)
    end

    it 'is false for any non-first worker regardless of PARALLEL_TEST_GROUPS' do
      ENV['TEST_ENV_NUMBER'] = '2'
      require 'parallel_tests'

      expect(described_class.last_process?).to be(false)
    end
  end

  describe '.remove_lock_file!' do
    it 'removes the lock file if present' do
      File.write(lock_file, '1')
      described_class.remove_lock_file!
      expect(File.exist?(lock_file)).to be(false)
    end

    it 'is a no-op when the lock file is already gone' do
      expect { described_class.remove_lock_file! }.not_to raise_error
    end
  end

  describe '.worker_group_count' do
    it 'returns 0 when PARALLEL_TEST_GROUPS is unset' do
      expect(described_class.worker_group_count).to eq(0)
    end

    it 'returns the integer value of PARALLEL_TEST_GROUPS' do
      ENV['PARALLEL_TEST_GROUPS'] = '4'
      expect(described_class.worker_group_count).to eq(4)
    end
  end

  describe '.peer_paths_for' do
    it 'returns only the existing parallel_tests_N subdirs' do
      ENV['PARALLEL_TEST_GROUPS'] = '3'
      base = File.join(tmp_base, 'peers')
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_1'))
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_3'))

      expect(described_class.peer_paths_for(base)).to contain_exactly(
        File.join(base, 'parallel_tests_1'),
        File.join(base, 'parallel_tests_3')
      )
    end
  end

  describe '.finalize!' do
    before do
      ENV['TEST_ENV_NUMBER'] = ''
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      File.write(lock_file, "2\n")
      require 'parallel_tests'
      allow(ParallelTests).to receive(:wait_for_other_processes_to_finish)
      allow(described_class).to receive(:merge_snapshot!)
      allow(described_class).to receive(:merge_coverage!)
      allow(described_class).to receive(:purge_worker_dirs!)
    end

    it 'is a no-op when parallel_tests is inactive' do
      ENV.delete('TEST_ENV_NUMBER')
      ENV.delete('PARALLEL_TEST_GROUPS')
      expect(described_class.finalize!).to be(false)
    end

    it 'is a no-op when this process is not the first worker' do
      ENV['TEST_ENV_NUMBER'] = '2'
      expect(described_class.finalize!).to be(false)
      expect(described_class).not_to have_received(:merge_snapshot!)
    end

    it 'runs the merge + cleanup sequence on the first (elected) worker' do
      result = described_class.finalize!

      expect(result).to be(true)
      expect(described_class).to have_received(:merge_snapshot!)
      expect(described_class).to have_received(:merge_coverage!)
      expect(described_class).to have_received(:purge_worker_dirs!)
      expect(File.exist?(lock_file)).to be(false)
    end

    it 'skips coverage merge when SimpleCov owns coverage emission' do
      allow(RSpecTracer).to receive(:simplecov?).and_return(true)

      described_class.finalize!

      expect(described_class).not_to have_received(:merge_coverage!)
    end

    it 'logs and returns false on StandardError — never propagates exit status' do
      allow(described_class).to receive(:merge_snapshot!).and_raise(StandardError, 'disk full')

      expect(described_class.finalize!).to be(false)
      expect(logger).to have_received(:warn).with(/parallel_tests finalize failed/)
    end
  end

  describe '.merge_snapshot!' do
    let(:schema) { RSpecTracer::Storage::Schema::CURRENT }
    let(:base_dir) { File.dirname(cache_path) }

    before do
      ENV['TEST_ENV_NUMBER'] = '1'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_1'))
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_2'))
    end

    it 'is a no-op when no peer directories exist' do
      FileUtils.rm_rf(base_dir)

      expect { described_class.merge_snapshot! }.not_to raise_error
    end

    it 'delegates to JsonBackend#merge_from_peers against the top-level cache dir' do
      backend = instance_double(RSpecTracer::Storage::JsonBackend, merge_from_peers: nil)
      expect(RSpecTracer::Storage::JsonBackend)
        .to receive(:new).with(cache_path: base_dir, logger: logger).and_return(backend)

      described_class.merge_snapshot!

      expect(backend).to have_received(:merge_from_peers).with(
        [File.join(base_dir, 'parallel_tests_1'), File.join(base_dir, 'parallel_tests_2')],
        schema_version: schema
      )
    end

    it 'emits a debug log line only when this worker is the narrator' do
      backend = instance_double(RSpecTracer::Storage::JsonBackend, merge_from_peers: nil)
      allow(RSpecTracer::Storage::JsonBackend).to receive(:new).and_return(backend)

      described_class.merge_snapshot!

      expect(logger).to have_received(:debug).with(/merged parallel tests reports/)
    end

    it 'suppresses the debug line for non-narrator workers unless verbose' do
      ENV['TEST_ENV_NUMBER'] = '2'
      backend = instance_double(RSpecTracer::Storage::JsonBackend, merge_from_peers: nil)
      allow(RSpecTracer::Storage::JsonBackend).to receive(:new).and_return(backend)

      described_class.merge_snapshot!

      expect(logger).not_to have_received(:debug)
    end
  end

  describe '.merge_coverage!' do
    let(:base_dir) { File.dirname(coverage_path) }

    before do
      ENV['TEST_ENV_NUMBER'] = '1'
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_1'))
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_2'))
    end

    it 'is a no-op when no peer coverage directories exist' do
      FileUtils.rm_rf(base_dir)

      expect { described_class.merge_coverage! }.not_to raise_error
    end

    it 'merges via CoverageMerger + writes the top-level coverage.json' do
      merger = spy('CoverageMerger')
      writer = spy('CoverageWriter')
      allow(RSpecTracer::CoverageMerger).to receive(:new).and_return(merger)
      allow(RSpecTracer::CoverageWriter).to receive(:new).and_return(writer)

      described_class.merge_coverage!

      expect(merger).to have_received(:merge).with(
        [File.join(base_dir, 'parallel_tests_1'), File.join(base_dir, 'parallel_tests_2')]
      )
      expect(RSpecTracer::CoverageWriter)
        .to have_received(:new).with(File.join(base_dir, 'coverage.json'), merger)
      expect(writer).to have_received(:write_report)
    end
  end

  describe '.purge_worker_dirs!' do
    it 'removes the parallel_tests_N subdirs under each tracked base dir' do
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      [cache_path, report_path, coverage_path].each do |path|
        FileUtils.mkdir_p(File.join(File.dirname(path), 'parallel_tests_1'))
        FileUtils.mkdir_p(File.join(File.dirname(path), 'parallel_tests_2'))
      end

      described_class.purge_worker_dirs!

      [cache_path, report_path, coverage_path].each do |path|
        (1..2).each do |n|
          expect(File.directory?(File.join(File.dirname(path), "parallel_tests_#{n}"))).to be(false)
        end
      end
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/VerifiedDoubles
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/StubbedMock, RSpec/MessageSpies
