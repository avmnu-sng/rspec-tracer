# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'
require 'tmpdir'
require 'time'
require 'rspec_tracer/storage/snapshot'
require 'rspec_tracer/reporters/json_reporter'

require_relative '../contracts/reporter'

# Thin spec: the payload-shape coverage now lives in
# payload_builder_spec.rb (JsonReporter delegates). This file asserts
# IO behavior + delegation + schema constant wiring.
# rubocop:disable RSpec/MultipleMemoizedHelpers
RSpec.describe RSpecTracer::Reporters::JsonReporter do
  let(:tmp) { Dir.mktmpdir }
  let(:empty_snapshot) { RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'empty') }
  let(:snapshot) { build_populated_snapshot }
  let(:run_metadata) do
    { pid: 1234, run_time: 4.25, started_at: Time.utc(2026, 4, 23, 12, 0, 0), parallel_tests: false }
  end
  let(:report_dir) { File.join(tmp, 'rspec_tracer_report') }
  let(:reporter_class) { described_class }

  after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

  def build_populated_snapshot
    RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'runabc').tap do |s|
      s.all_examples = {
        'ex1' => {
          full_description: 'First example',
          rerun_file_name: '/spec/a_spec.rb',
          rerun_line_number: 1,
          execution_result: { status: :passed, run_time: 0.01 }
        }
      }
      s.dependency = { 'ex1' => Set.new(['/lib/a.rb']) }
      s.reverse_dependency = { '/lib/a.rb' => Set.new(['ex1']) }
    end
  end

  def build_reporter(snap: snapshot, metadata: run_metadata)
    described_class.new(
      snapshot: snap, report_dir: report_dir, run_metadata: metadata, logger: nil
    )
  end

  def read_payload
    JSON.parse(File.read(File.join(report_dir, 'report.json')))
  end

  it_behaves_like 'a Reporters::Base'

  describe '#generate (no-op path)' do
    it 'returns nil when the snapshot has no tracked examples' do
      expect(build_reporter(snap: empty_snapshot).generate).to be_nil
    end

    it 'does not create the report file on no-op' do
      build_reporter(snap: empty_snapshot).generate

      expect(File).not_to exist(File.join(report_dir, 'report.json'))
    end
  end

  describe '#generate (populated path)' do
    it 'creates the report_dir if missing' do
      build_reporter.generate

      expect(File).to be_directory(report_dir)
    end

    it 'writes report.json under report_dir' do
      build_reporter.generate

      expect(File).to exist(File.join(report_dir, 'report.json'))
    end

    it 'returns the written path' do
      expect(build_reporter.generate).to eq(File.join(report_dir, 'report.json'))
    end

    it 'logs a debug line through the provided logger' do
      logger = instance_double(RSpecTracer::Logger, debug: nil)
      described_class.new(
        snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata, logger: logger
      ).generate

      expect(logger).to have_received(:debug).with(/wrote report JSON/)
    end

    it 'writes JSON that round-trips as the payload envelope' do
      build_reporter.generate

      expect(read_payload.keys).to contain_exactly(
        'schema_version', 'run_id', 'generated_at', 'summary', 'reports'
      )
    end

    it 'pretty-prints the JSON (multi-line output)' do
      build_reporter.generate
      raw = File.read(File.join(report_dir, 'report.json'))

      expect(raw.lines.count).to be > 1
    end
  end

  describe 'SCHEMA_VERSION constant' do
    it 'delegates to PayloadBuilder::SCHEMA_VERSION' do
      expect(described_class::SCHEMA_VERSION)
        .to eq(RSpecTracer::Reporters::PayloadBuilder::SCHEMA_VERSION)
    end

    it 'is pinned to 1 for the initial reporter schema' do
      expect(described_class::SCHEMA_VERSION).to eq(1)
    end
  end

  describe 'FILENAME constant' do
    it 'is report.json' do
      expect(described_class::FILENAME).to eq('report.json')
    end
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers
