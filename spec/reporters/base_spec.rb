# frozen_string_literal: true

require 'set'
require 'tmpdir'
require 'rspec_tracer/storage/snapshot'
require 'rspec_tracer/reporters/base'

RSpec.describe RSpecTracer::Reporters::Base do
  let(:tmp) { Dir.mktmpdir }
  let(:snapshot) do
    RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'r').tap do |s|
      s.all_examples = { 'ex1' => { id: 'ex1' } }
    end
  end
  let(:empty_snapshot) { RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'r') }

  after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

  describe '#initialize' do
    it 'exposes the snapshot' do
      reporter = described_class.new(snapshot: snapshot, report_dir: tmp, run_metadata: { pid: 1 })

      expect(reporter.snapshot).to be(snapshot)
    end

    it 'exposes the report_dir' do
      reporter = described_class.new(snapshot: snapshot, report_dir: tmp, run_metadata: {})

      expect(reporter.report_dir).to eq(tmp)
    end

    it 'exposes run_metadata as a Hash' do
      meta = { pid: 7 }
      reporter = described_class.new(snapshot: snapshot, report_dir: tmp, run_metadata: meta)

      expect(reporter.run_metadata).to eq(meta)
    end

    it 'coerces a nil run_metadata to an empty Hash (defensive for custom callers)' do
      reporter = described_class.new(snapshot: snapshot, report_dir: tmp, run_metadata: nil)

      expect(reporter.run_metadata).to eq({})
    end

    it 'captures the optional logger' do
      logger = instance_double(RSpecTracer::Logger)
      reporter = described_class.new(snapshot: snapshot, report_dir: tmp, run_metadata: {}, logger: logger)

      expect(reporter.logger).to be(logger)
    end

    it 'captures arbitrary **opts into options' do
      reporter = described_class.new(snapshot: snapshot, report_dir: tmp, run_metadata: {}, something: 42)

      expect(reporter.options).to eq(something: 42)
    end
  end

  describe '#generate' do
    it 'raises NotImplementedError to force subclass override' do
      reporter = described_class.new(snapshot: snapshot, report_dir: tmp, run_metadata: {})

      expect { reporter.generate }.to raise_error(NotImplementedError, /generate must be implemented/)
    end
  end

  describe '#no_op?' do
    it 'is true when snapshot is nil' do
      reporter = described_class.new(snapshot: nil, report_dir: tmp, run_metadata: {})

      expect(reporter.no_op?).to be(true)
    end

    it 'is true when snapshot.all_examples is nil' do
      snap = RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'r')
      snap.all_examples = nil
      reporter = described_class.new(snapshot: snap, report_dir: tmp, run_metadata: {})

      expect(reporter.no_op?).to be(true)
    end

    it 'is true when snapshot.all_examples is an empty Hash' do
      reporter = described_class.new(snapshot: empty_snapshot, report_dir: tmp, run_metadata: {})

      expect(reporter.no_op?).to be(true)
    end

    it 'is false when at least one example is present' do
      reporter = described_class.new(snapshot: snapshot, report_dir: tmp, run_metadata: {})

      expect(reporter.no_op?).to be(false)
    end
  end
end
