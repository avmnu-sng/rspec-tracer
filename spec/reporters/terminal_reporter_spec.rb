# frozen_string_literal: true

require 'set'
require 'stringio'
require 'tmpdir'
require 'rspec_tracer/storage/snapshot'
require 'rspec_tracer/reporters/terminal_reporter'

require_relative '../contracts/reporter'

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/MultipleExpectations
RSpec.describe RSpecTracer::Reporters::TerminalReporter do
  let(:reporter_class) { described_class }
  let(:empty_snapshot) { RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'empty') }
  let(:io) { StringIO.new }
  let(:run_metadata) { { cache_path: '/fake/cache/path' } }
  let(:snapshot) { build_populated_snapshot }
  let(:report_dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(report_dir) if File.directory?(report_dir) }

  def build_populated_snapshot(overrides = {})
    RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'rid').tap do |s|
      s.all_examples = {
        'ex1' => { execution_result: { status: 'passed' } },
        'ex2' => {},
        'ex3' => { execution_result: { status: 'passed' } }
      }
      s.skipped_examples = Set.new(['ex2'])
      overrides.each { |k, v| s.send("#{k}=", v) }
    end
  end

  def build_reporter(snap: snapshot, metadata: run_metadata, io_override: io)
    described_class.new(
      snapshot: snap, report_dir: report_dir,
      run_metadata: metadata, logger: nil, io: io_override
    )
  end

  it_behaves_like 'a Reporters::Base'

  describe '#generate (no-op path)' do
    it 'returns nil on empty snapshot' do
      expect(build_reporter(snap: empty_snapshot).generate).to be_nil
    end

    it 'emits no output on empty snapshot' do
      build_reporter(snap: empty_snapshot).generate

      expect(io.string).to be_empty
    end
  end

  describe '#generate (populated path)' do
    it 'emits the header line with counts and cache percent' do
      build_reporter.generate

      expect(io.string).to include('rspec-tracer: 3 examples tracked')
      expect(io.string).to include('2 re-run')
      expect(io.string).to include('1 skipped')
      expect(io.string).to include('33% cached')
    end

    it 'emits a cache line when cache_path is in run_metadata' do
      build_reporter.generate

      expect(io.string).to include('cache: /fake/cache/path')
    end

    it 'omits the cache line when cache_path is absent' do
      build_reporter(metadata: {}).generate

      expect(io.string).not_to include('cache:')
    end

    it 'omits the cache line when cache_path is empty' do
      build_reporter(metadata: { cache_path: '' }).generate

      expect(io.string).not_to include('cache:')
    end

    it 'emits a report line pointing at report.json' do
      build_reporter.generate

      expect(io.string).to include("report: #{File.join(report_dir, 'report.json')}")
    end

    it 'omits the report line when report_dir is nil' do
      reporter = described_class.new(
        snapshot: snapshot, report_dir: nil, run_metadata: run_metadata, logger: nil, io: io
      )
      reporter.generate

      expect(io.string).not_to include('report:')
    end

    it 'omits the report line when report_dir is empty' do
      reporter = described_class.new(
        snapshot: snapshot, report_dir: '', run_metadata: run_metadata, logger: nil, io: io
      )
      reporter.generate

      expect(io.string).not_to include('report:')
    end

    it 'skips the tally line when no conditional counter is non-zero' do
      build_reporter.generate

      expect(io.string).not_to match(/^\d+ (failed|pending|flaky|interrupted|duplicate)/)
    end

    it 'adds a tally line when failed_examples is non-empty' do
      snap = build_populated_snapshot(failed_examples: Set.new(['ex1']))
      build_reporter(snap: snap).generate

      expect(io.string).to include('1 failed')
    end

    it 'adds a tally line when pending_examples is non-empty' do
      snap = build_populated_snapshot(pending_examples: Set.new(['ex1']))
      build_reporter(snap: snap).generate

      expect(io.string).to include('1 pending')
    end

    it 'adds a tally line when flaky_examples is non-empty' do
      snap = build_populated_snapshot(flaky_examples: Set.new(['ex1']))
      build_reporter(snap: snap).generate

      expect(io.string).to include('1 flaky')
    end

    it 'adds a tally line when interrupted_examples is non-empty' do
      snap = build_populated_snapshot(interrupted_examples: Set.new(['ex1']))
      build_reporter(snap: snap).generate

      expect(io.string).to include('1 interrupted')
    end

    it 'adds a tally line when duplicate_examples is non-empty' do
      snap = build_populated_snapshot(
        duplicate_examples: { 'dup' => [{}, {}] }
      )
      build_reporter(snap: snap).generate

      expect(io.string).to include('1 duplicate')
    end

    it 'caps output at 4 lines in the happy path (header + cache + report) when no kind-breakdown' do
      result = build_reporter.generate

      expect(result.length).to be <= 4
    end

    it 'returns the emitted lines as an Array' do
      expect(build_reporter.generate).to be_an(Array)
    end
  end

  describe 'kind-breakdown line (cache_hit_reason aggregate)' do
    it 'omits the line when snapshot.cache_hit_reason is empty' do
      build_reporter.generate

      expect(io.string).not_to include('by reason:')
    end

    it 'emits per-reason counts when populated' do
      reasons = { 'Files changed' => 12, 'No cache' => 5, 'Environment changed' => 3 }
      build_reporter(snap: build_populated_snapshot(cache_hit_reason: reasons)).generate

      expect(io.string).to include('by reason:', '12 Files changed', '5 No cache', '3 Environment changed')
    end

    it 'sorts breakdown parts by count descending' do
      reasons = { 'No cache' => 1, 'Files changed' => 99, 'Environment changed' => 7 }
      build_reporter(snap: build_populated_snapshot(cache_hit_reason: reasons)).generate
      line = io.string.lines.find { |l| l.include?('by reason:') }

      expect(line.index('99 Files changed')).to be < line.index('7 Environment changed')
    end
  end

  describe 'cache size + delta suffix' do
    let(:cache_root) { Dir.mktmpdir }
    let(:size_reporter) do
      described_class.new(
        snapshot: build_populated_snapshot, report_dir: report_dir,
        run_metadata: metadata_with_cache, logger: nil, io: io
      )
    end
    let(:metadata_with_cache) { { cache_path: cache_root } }

    after { FileUtils.remove_entry(cache_root) if File.directory?(cache_root) }

    def write_run_dir(run_id, byte_size)
      run_dir = File.join(cache_root, run_id)
      FileUtils.mkdir_p(run_dir)
      File.binwrite(File.join(run_dir, 'sample.json'), "\x00" * byte_size)
      run_dir
    end

    def cache_line_in_output
      io.string.lines.find { |l| l.start_with?('cache:') }
    end

    it 'emits size only when no prior run dir exists' do
      write_run_dir('rid', 4096)
      size_reporter.generate

      expect(cache_line_in_output).to include("(4.0 KiB)\n")
      expect(cache_line_in_output).not_to include('vs prev run')
    end

    it 'emits size + signed delta when a prior run dir is present' do
      File.utime(Time.now - 60, Time.now - 60, write_run_dir('rid-prev', 1024))
      write_run_dir('rid', 4096)
      size_reporter.generate

      expect(cache_line_in_output).to include('4.0 KiB', '+3.0 KiB vs prev run')
    end

    it 'emits a negative delta when the current run is smaller than the prior' do
      prior = write_run_dir('rid-prev', 8192)
      File.utime(Time.now - 60, Time.now - 60, prior)
      write_run_dir('rid', 1024)
      size_reporter.generate

      expect(cache_line_in_output).to include('-7.0 KiB vs prev run')
    end

    it 'omits the size suffix entirely when the current run dir is missing' do
      size_reporter.generate

      expect(cache_line_in_output).to eq("cache: #{cache_root}\n")
    end

    it 'formats sub-KiB sizes in bytes' do
      write_run_dir('rid', 256)
      size_reporter.generate

      expect(cache_line_in_output).to include('256 B')
    end

    it 'formats megabyte+ sizes in MiB' do
      write_run_dir('rid', 5 * 1_048_576)
      size_reporter.generate

      expect(cache_line_in_output).to include('5.0 MiB')
    end

    it 'returns empty suffix when the current run dir does not exist' do
      expect(size_reporter.send(:cache_size_suffix, cache_root)).to eq('')
    end

    it 'rescues filesystem errors silently and returns empty suffix' do
      write_run_dir('rid', 4096)
      allow(size_reporter).to receive(:directory_size_bytes).and_raise(Errno::EACCES)

      expect(size_reporter.send(:cache_size_suffix, cache_root)).to eq('')
    end

    it 'returns empty suffix when the snapshot run_id is nil' do
      blank_id_reporter = described_class.new(
        snapshot: build_populated_snapshot(run_id: nil), report_dir: report_dir,
        run_metadata: metadata_with_cache, logger: nil, io: io
      )

      expect(blank_id_reporter.send(:cache_size_suffix, cache_root)).to eq('')
    end

    it 'returns empty suffix when the snapshot run_id is an empty string' do
      blank_id_reporter = described_class.new(
        snapshot: build_populated_snapshot(run_id: ''), report_dir: report_dir,
        run_metadata: metadata_with_cache, logger: nil, io: io
      )

      expect(blank_id_reporter.send(:cache_size_suffix, cache_root)).to eq('')
    end

    it 'omits the sign character when delta is zero (no growth or shrink)' do
      File.utime(Time.now - 60, Time.now - 60, write_run_dir('rid-prev', 2048))
      write_run_dir('rid', 2048)
      size_reporter.generate

      # delta == 0 hits the inner ternary's else branch, so the sign char
      # is empty: "(<size>; 0 B vs prev run)".
      expect(cache_line_in_output).to match(/\(2\.0 KiB; 0 B vs prev run\)/)
    end

    it 'sums only file entries when the run dir contains nested subdirectories' do
      run_dir = write_run_dir('rid', 4096)
      # Adding an empty subdir surfaces a Dir glob entry that fails File.file?
      # — exercises directory_size_bytes' :else branch (skip-with-zero).
      FileUtils.mkdir_p(File.join(run_dir, 'nested'))
      size_reporter.generate

      expect(cache_line_in_output).to include('4.0 KiB')
    end
  end

  describe 'color policy' do
    let(:tty_io) do
      Class.new(StringIO) do
        def tty?
          true
        end
      end.new
    end

    it 'emits ANSI codes when the stream is a TTY and NO_COLOR unset' do
      stub_const('ENV', ENV.to_hash.merge.tap { |h| h.delete('NO_COLOR') })
      build_reporter(io_override: tty_io).generate

      expect(tty_io.string).to include("\e[")
    end

    it 'omits ANSI codes when NO_COLOR is set (any value disables)' do
      stub_const('ENV', ENV.to_hash.merge('NO_COLOR' => '1'))
      build_reporter(io_override: tty_io).generate

      expect(tty_io.string).not_to include("\e[")
    end

    it 'omits ANSI codes when stream is not a TTY' do
      build_reporter.generate

      expect(io.string).not_to include("\e[")
    end

    it 'paints red when any example failed' do
      stub_const('ENV', ENV.to_hash.merge.tap { |h| h.delete('NO_COLOR') })
      snap = build_populated_snapshot(failed_examples: Set.new(['ex1']))
      build_reporter(snap: snap, io_override: tty_io).generate

      expect(tty_io.string).to include("\e[31m")
    end

    it 'paints red when any example was interrupted' do
      stub_const('ENV', ENV.to_hash.merge.tap { |h| h.delete('NO_COLOR') })
      snap = build_populated_snapshot(interrupted_examples: Set.new(['ex1']))
      build_reporter(snap: snap, io_override: tty_io).generate

      expect(tty_io.string).to include("\e[31m")
    end

    it 'paints yellow when only pending examples are present' do
      stub_const('ENV', ENV.to_hash.merge.tap { |h| h.delete('NO_COLOR') })
      snap = build_populated_snapshot(pending_examples: Set.new(['ex1']))
      build_reporter(snap: snap, io_override: tty_io).generate

      expect(tty_io.string).to include("\e[33m")
    end

    it 'paints green on a fully successful run' do
      stub_const('ENV', ENV.to_hash.merge.tap { |h| h.delete('NO_COLOR') })
      build_reporter(io_override: tty_io).generate

      expect(tty_io.string).to include("\e[32m")
    end

    it 'falls back to reset when paint is called with an unknown color key' do
      reporter = build_reporter(io_override: tty_io)
      stub_const('ENV', ENV.to_hash.merge.tap { |h| h.delete('NO_COLOR') })

      result = reporter.send(:paint, :no_such_color, 'text')

      expect(result).to start_with("\e[0m")
    end
  end

  describe 'cache-percent edge cases' do
    it 'returns 0% cached when total is zero (defensive; no_op? would normally short-circuit)' do
      reporter = build_reporter(snap: snapshot)
      expect(reporter.send(:cache_percent, 0, 0)).to eq(0)
    end

    it 'rounds to nearest integer' do
      reporter = build_reporter(snap: snapshot)
      expect(reporter.send(:cache_percent, 3, 1)).to eq(33)
    end
  end

  describe 'output_stream default' do
    it 'uses $stdout when no :io option is provided' do
      reporter = described_class.new(
        snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata, logger: nil
      )

      expect(reporter.send(:output_stream)).to be($stdout)
    end
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/MultipleExpectations
