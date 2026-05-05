# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'logger'
require 'stringio'
require 'tmpdir'

# Regression coverage for v1.2.1's fix to the parallel_tests merge +
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
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
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

  # Regression coverage for the GHA-observed parallel_tests purge race:
  # ParallelTests.wait_for_other_processes_to_finish (pid-file based)
  # could return while a sibling worker hadn't fully flushed its
  # parallel_tests_N/ dir yet. The boot/done filesystem markers cross-
  # check the pid signal so the elected worker waits for every booted
  # peer's `.done` to materialize before merge + purge.
  describe 'parallel_tests boot/done barrier' do
    let(:tmp_root) { Dir.mktmpdir }
    let(:cache_path) { File.join(tmp_root, 'rspec_tracer_cache', 'parallel_tests_1') }
    let(:base_dir) { File.dirname(cache_path) }
    let(:logger) { Logger.new(StringIO.new) }

    before do
      allow(described_class).to receive_messages(cache_path: cache_path, logger: logger)
      FileUtils.mkdir_p(cache_path)
    end

    after { FileUtils.rm_rf(tmp_root) }

    def write_marker(worker_index, marker_filename, contents = 'x')
      dir = File.join(base_dir, "parallel_tests_#{worker_index}")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, marker_filename), contents)
    end

    describe '.parallel_tests_touch_boot!' do
      it 'is a no-op when parallel_tests is inactive' do
        allow(described_class).to receive(:parallel_tests?).and_return(false)

        described_class.send(:parallel_tests_touch_boot!)

        expect(File).not_to exist(File.join(cache_path, RSpecTracer::PARALLEL_TESTS_BOOT_MARKER_FILENAME))
      end

      it 'writes a JSON-encoded boot marker with pid + test_env_number' do
        allow(described_class).to receive(:parallel_tests?).and_return(true)
        ENV['TEST_ENV_NUMBER'] = '3'

        described_class.send(:parallel_tests_touch_boot!)

        marker = File.join(cache_path, RSpecTracer::PARALLEL_TESTS_BOOT_MARKER_FILENAME)
        payload = JSON.parse(File.read(marker))
        expect(payload).to include('pid' => Process.pid, 'test_env_number' => '3')
      ensure
        ENV.delete('TEST_ENV_NUMBER')
      end

      it 'absorbs filesystem failure with a logger.warn (graceful degradation)' do
        allow(described_class).to receive(:parallel_tests?).and_return(true)
        allow(File).to receive(:write).and_raise(Errno::EACCES, 'no perms')
        allow(logger).to receive(:warn)

        expect { described_class.send(:parallel_tests_touch_boot!) }.not_to raise_error
        expect(logger).to have_received(:warn).with(/failed to write boot marker/)
      end
    end

    describe '.parallel_tests_touch_done!' do
      it 'is a no-op when parallel_tests is inactive' do
        allow(described_class).to receive(:parallel_tests?).and_return(false)

        described_class.send(:parallel_tests_touch_done!)

        expect(File).not_to exist(File.join(cache_path, RSpecTracer::PARALLEL_TESTS_DONE_MARKER_FILENAME))
      end

      it 'writes the done marker with an iso8601 timestamp' do
        allow(described_class).to receive(:parallel_tests?).and_return(true)

        described_class.send(:parallel_tests_touch_done!)

        marker = File.join(cache_path, RSpecTracer::PARALLEL_TESTS_DONE_MARKER_FILENAME)
        expect(File.read(marker)).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
      end

      it 'absorbs filesystem failure with a logger.warn (graceful degradation)' do
        allow(described_class).to receive(:parallel_tests?).and_return(true)
        allow(File).to receive(:write).and_raise(Errno::EACCES, 'no perms')
        allow(logger).to receive(:warn)

        expect { described_class.send(:parallel_tests_touch_done!) }.not_to raise_error
        expect(logger).to have_received(:warn).with(/failed to write done marker/)
      end
    end

    describe '.parallel_tests_peer_dirs_missing_done' do
      it 'returns peers with .boot but no .done' do
        write_marker(1, RSpecTracer::PARALLEL_TESTS_BOOT_MARKER_FILENAME)
        write_marker(1, RSpecTracer::PARALLEL_TESTS_DONE_MARKER_FILENAME)
        write_marker(2, RSpecTracer::PARALLEL_TESTS_BOOT_MARKER_FILENAME)
        # peer 2 has no .done

        missing = described_class.send(:parallel_tests_peer_dirs_missing_done, base_dir)

        expect(missing).to contain_exactly(File.join(base_dir, 'parallel_tests_2'))
      end

      it 'returns [] when every booted peer has finished' do
        write_marker(1, RSpecTracer::PARALLEL_TESTS_BOOT_MARKER_FILENAME)
        write_marker(1, RSpecTracer::PARALLEL_TESTS_DONE_MARKER_FILENAME)

        expect(described_class.send(:parallel_tests_peer_dirs_missing_done, base_dir)).to eq([])
      end

      it 'returns [] when no peers have booted' do
        expect(described_class.send(:parallel_tests_peer_dirs_missing_done, base_dir)).to eq([])
      end
    end

    describe '.parallel_tests_wait_for_peer_done_markers!' do
      it 'returns immediately when every booted peer has its done marker' do
        write_marker(1, RSpecTracer::PARALLEL_TESTS_BOOT_MARKER_FILENAME)
        write_marker(1, RSpecTracer::PARALLEL_TESTS_DONE_MARKER_FILENAME)
        write_marker(2, RSpecTracer::PARALLEL_TESTS_BOOT_MARKER_FILENAME)
        write_marker(2, RSpecTracer::PARALLEL_TESTS_DONE_MARKER_FILENAME)

        expect { described_class.send(:parallel_tests_wait_for_peer_done_markers!) }.not_to raise_error
      end

      it 'returns immediately when no peers have booted' do
        expect { described_class.send(:parallel_tests_wait_for_peer_done_markers!) }.not_to raise_error
      end

      it 'logs a warn and proceeds at the deadline when a peer never signals done' do
        write_marker(1, RSpecTracer::PARALLEL_TESTS_BOOT_MARKER_FILENAME)
        write_marker(1, RSpecTracer::PARALLEL_TESTS_DONE_MARKER_FILENAME)
        write_marker(2, RSpecTracer::PARALLEL_TESTS_BOOT_MARKER_FILENAME)
        # peer 2 never writes .done — deadline elapses
        stub_const("#{described_class}::PARALLEL_TESTS_PEER_DONE_DEADLINE_SECONDS", 0)
        allow(described_class).to receive(:sleep)
        allow(logger).to receive(:warn)

        expect { described_class.send(:parallel_tests_wait_for_peer_done_markers!) }.not_to raise_error
        expect(logger).to have_received(:warn).with(/peers booted without finishing within/)
      end

      it 'recovers within the deadline when a slow peer eventually flushes' do
        write_marker(1, RSpecTracer::PARALLEL_TESTS_BOOT_MARKER_FILENAME)
        write_marker(1, RSpecTracer::PARALLEL_TESTS_DONE_MARKER_FILENAME)
        write_marker(2, RSpecTracer::PARALLEL_TESTS_BOOT_MARKER_FILENAME)

        polls = 0
        allow(described_class).to receive(:sleep) do
          polls += 1
          write_marker(2, RSpecTracer::PARALLEL_TESTS_DONE_MARKER_FILENAME) if polls == 1
        end

        expect { described_class.send(:parallel_tests_wait_for_peer_done_markers!) }.not_to raise_error
      end
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
