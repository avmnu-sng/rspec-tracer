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

    it 'caps output at 4 lines in the happy path (header + cache + report)' do
      result = build_reporter.generate

      expect(result.length).to be <= 4
    end

    it 'returns the emitted lines as an Array' do
      expect(build_reporter.generate).to be_an(Array)
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
