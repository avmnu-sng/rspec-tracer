# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

# Regression coverage for v1.0.2's fix to the parallel_tests merge +
# purge paths in lib/rspec_tracer.rb. parallel_tests sets
# PARALLEL_TEST_GROUPS to the user-requested process count (the
# CPU-derived num_processes), not the actual worker count - so the
# 1.upto(ENV['PARALLEL_TEST_GROUPS']) iteration earlier patches used
# silently dropped peer caches and left straggler dirs whenever the
# spawned-worker count exceeded num_processes. Globbing
# `parallel_tests_*` subdirectories is robust regardless.
#
# These tests target the private singleton helpers via `.send` because
# they were extracted purely to make the iteration testable; they
# remain implementation detail of the at_exit pipeline.
# rubocop:disable RSpec/ExampleLength
RSpec.describe RSpecTracer do
  describe '.parallel_tests_peer_dirs' do
    subject(:peer_dirs) { described_class.send(:parallel_tests_peer_dirs, base_dir) }

    let(:base_dir) { Dir.mktmpdir }

    after { FileUtils.rm_rf(base_dir) }

    it 'returns every parallel_tests_* subdirectory under base_dir' do
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_1'))
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_2'))
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_4'))

      expect(peer_dirs).to contain_exactly(
        File.join(base_dir, 'parallel_tests_1'),
        File.join(base_dir, 'parallel_tests_2'),
        File.join(base_dir, 'parallel_tests_4')
      )
    end

    it 'finds peer dirs whose index exceeds PARALLEL_TEST_GROUPS' do
      ENV['PARALLEL_TEST_GROUPS'] = '2'

      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_1'))
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_2'))
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_4'))

      expect(peer_dirs).to include(File.join(base_dir, 'parallel_tests_4'))
    ensure
      ENV.delete('PARALLEL_TEST_GROUPS')
    end

    it 'finds peer dirs even when PARALLEL_TEST_GROUPS is unset' do
      ENV.delete('PARALLEL_TEST_GROUPS')
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_1'))

      expect(peer_dirs).to contain_exactly(File.join(base_dir, 'parallel_tests_1'))
    end

    it 'returns an empty array when no parallel_tests_* dirs exist' do
      expect(peer_dirs).to eq([])
    end

    it 'rejects file entries with the parallel_tests_ prefix' do
      FileUtils.mkdir_p(File.join(base_dir, 'parallel_tests_1'))
      File.write(File.join(base_dir, 'parallel_tests_2.json'), 'not a dir')

      expect(peer_dirs).to contain_exactly(File.join(base_dir, 'parallel_tests_1'))
    end
  end

  describe '.purge_parallel_tests_reports' do
    let(:tmp_root)      { Dir.mktmpdir }
    let(:cache_path)    { File.join(tmp_root, 'rspec_tracer_cache', 'parallel_tests_1') }
    let(:coverage_path) { File.join(tmp_root, 'rspec_tracer_coverage', 'parallel_tests_1') }
    let(:report_path)   { File.join(tmp_root, 'rspec_tracer_report', 'parallel_tests_1') }

    before do
      allow(described_class).to receive_messages(
        cache_path: cache_path, coverage_path: coverage_path, report_path: report_path
      )
      allow(described_class).to receive(:parallel_tests_executed?).and_return(true)
      [cache_path, coverage_path, report_path].each { |p| FileUtils.mkdir_p(File.dirname(p)) }
    end

    after { FileUtils.rm_rf(tmp_root) }

    it 'sweeps every parallel_tests_* subdir under each tracked base dir' do
      [cache_path, coverage_path, report_path].each do |path|
        base = File.dirname(path)
        FileUtils.mkdir_p(File.join(base, 'parallel_tests_1'))
        FileUtils.mkdir_p(File.join(base, 'parallel_tests_2'))
      end

      described_class.send(:purge_parallel_tests_reports)

      [cache_path, coverage_path, report_path].each do |path|
        expect(Dir.glob(File.join(File.dirname(path), 'parallel_tests_*'))).to be_empty
      end
    end

    # Regression: the bug we're fixing. Worker dirs whose index >
    # PARALLEL_TEST_GROUPS used to be left behind because the iteration
    # bound was env-derived, not filesystem-derived.
    it 'sweeps worker dirs whose index exceeds PARALLEL_TEST_GROUPS' do
      ENV['PARALLEL_TEST_GROUPS'] = '2'
      base = File.dirname(cache_path)
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_1'))
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_4'))

      described_class.send(:purge_parallel_tests_reports)

      expect(Dir.glob(File.join(base, 'parallel_tests_*'))).to be_empty
    ensure
      ENV.delete('PARALLEL_TEST_GROUPS')
    end

    it 'is a no-op when parallel_tests has not executed' do
      allow(described_class).to receive(:parallel_tests_executed?).and_return(false)
      base = File.dirname(cache_path)
      FileUtils.mkdir_p(File.join(base, 'parallel_tests_1'))

      described_class.send(:purge_parallel_tests_reports)

      expect(File.directory?(File.join(base, 'parallel_tests_1'))).to be(true)
    end
  end
end
# rubocop:enable RSpec/ExampleLength
