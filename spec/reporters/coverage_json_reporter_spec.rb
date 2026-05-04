# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'
require 'tmpdir'
require 'rspec_tracer'
require 'rspec_tracer/storage/snapshot'
require 'rspec_tracer/reporters/coverage_json_reporter'

require_relative '../contracts/reporter'

# Unit + structural coverage for the M8.0 coverage.json emitter.
# Round-trip byte-equivalence vs the rails_app fixture's golden
# lives in spec/integration/coverage_json_round_trip_spec.rb (driven
# end-to-end through a subprocess); this file exercises the emitter
# in isolation against stubbed RSpecTracer + Engine surface so each
# branch is reachable on MRI.
# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe RSpecTracer::Reporters::CoverageJsonReporter do
  let(:tmp) { Dir.mktmpdir }
  let(:fixture_root) { File.join(tmp, 'project') }
  let(:coverage_dir) { File.join(tmp, 'coverage_out') }
  let(:report_dir) { File.join(tmp, 'reports') }
  let(:tracked_file) { File.join(fixture_root, 'lib', 'tracked.rb') }
  let(:other_file) { File.join(fixture_root, 'lib', 'other.rb') }
  let(:filtered_file) { File.join(fixture_root, 'spec', 'foo_spec.rb') }
  let(:empty_snapshot) { RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'empty') }
  let(:snapshot) do
    RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'r').tap do |s|
      s.all_examples = { 'ex1' => { full_description: 'A' } }
    end
  end
  let(:run_metadata) { {} }
  let(:reporter_class) { described_class }
  let(:registry) { instance_double(RSpecTracer::Tracker::ExampleRegistry) }
  let(:adapter) { instance_double(RSpecTracer::Tracker::CoverageAdapter) }
  let(:engine) do
    instance_double(
      RSpecTracer::Engine,
      coverage_adapter: adapter,
      registry: registry,
      merge_skipped_coverage: {}
    )
  end

  before do
    FileUtils.mkdir_p(File.join(fixture_root, 'lib'))
    FileUtils.mkdir_p(File.join(fixture_root, 'spec'))
    File.write(tracked_file, "x = 1\ny = 2\n")
    File.write(other_file, "z = 3\n")
    File.write(filtered_file, "fail\n")

    allow(RSpecTracer).to receive_messages(
      engine: engine,
      coverage_path: coverage_dir,
      coverage_filters: [],
      coverage_tracked_files: nil,
      simplecov?: false,
      root: fixture_root
    )
    allow(adapter).to receive(:peek_unfiltered).and_return({})
    allow(registry).to receive(:ids_with_status).with(:skipped).and_return([])
  end

  after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

  # Skip the `a Reporters::Base` shared contract: that contract expects
  # no_op? = true on empty snapshots, but coverage.json must emit
  # unconditionally to match 1.x behavior (legacy CoverageReporter
  # writes coverage.json with stub-only entries when no examples ran).
  describe 'input envelope' do
    it 'accepts (snapshot:, report_dir:, run_metadata:, logger:)' do
      expect do
        described_class.new(
          snapshot: snapshot, report_dir: report_dir, run_metadata: {}, logger: nil
        )
      end.not_to raise_error
    end

    it 'accepts extra **opts without raising' do
      expect do
        described_class.new(
          snapshot: snapshot, report_dir: report_dir, run_metadata: {}, logger: nil, custom: true
        )
      end.not_to raise_error
    end
  end

  describe '#no_op?' do
    it 'is always false (coverage.json must emit even on empty snapshots)' do
      reporter = described_class.new(
        snapshot: empty_snapshot, report_dir: report_dir, run_metadata: {}, logger: nil
      )

      expect(reporter.no_op?).to be(false)
    end
  end

  describe '#generate' do
    it 'returns nil and skips emission when RSpecTracer.engine is nil' do
      allow(RSpecTracer).to receive(:engine).and_return(nil)
      reporter = described_class.new(
        snapshot: empty_snapshot, report_dir: report_dir, run_metadata: {}, logger: nil
      )

      expect(reporter.generate).to be_nil
      expect(File).not_to exist(File.join(coverage_dir, 'coverage.json'))
    end

    it 'creates coverage_path and writes the canonical JSON envelope' do
      allow(adapter).to receive(:peek_unfiltered).and_return(tracked_file => [1, 1])

      result = build_reporter.generate

      expect(result).to eq(File.join(coverage_dir, 'coverage.json'))
      expect(File).to be_directory(coverage_dir)

      payload = JSON.parse(File.read(result, encoding: 'UTF-8'))
      expect(payload.keys).to eq(['RSpecTracer'])
      expect(payload['RSpecTracer']['coverage']).to eq(tracked_file => [1, 1])
      expect(payload['RSpecTracer']['timestamp']).to be_a(Integer)
    end

    it 'sorts the file list and stubs files added via coverage_tracked_files' do
      allow(adapter).to receive(:peek_unfiltered).and_return(other_file => [1])
      allow(RSpecTracer).to receive(:coverage_tracked_files).and_return(
        File.join(fixture_root, 'lib', '*.rb')
      )

      build_reporter.generate

      payload = JSON.parse(File.read(File.join(coverage_dir, 'coverage.json'), encoding: 'UTF-8'))
      keys = payload['RSpecTracer']['coverage'].keys
      expect(keys).to eq(keys.sort)
      expect(keys).to include(tracked_file, other_file)
      expect(payload['RSpecTracer']['coverage'][tracked_file]).to eq([0, 0])
    end

    it 'applies coverage_filters by file name (matches legacy CoverageReporter#final_coverage_files)' do
      allow(adapter).to receive(:peek_unfiltered).and_return(
        tracked_file => [1, 1], filtered_file => [1]
      )
      filter = RSpecTracer::Filter.register(%r{^/spec/})
      allow(RSpecTracer).to receive(:coverage_filters).and_return([filter])

      build_reporter.generate

      payload = JSON.parse(File.read(File.join(coverage_dir, 'coverage.json'), encoding: 'UTF-8'))
      expect(payload['RSpecTracer']['coverage'].keys).to eq([tracked_file])
    end

    it 'logs covered/total LOC + percent through the provided logger' do
      allow(adapter).to receive(:peek_unfiltered).and_return(tracked_file => [1, nil])
      logger = instance_double(RSpecTracer::Logger, info: nil)

      described_class.new(
        snapshot: snapshot, report_dir: report_dir, run_metadata: {}, logger: logger
      ).generate

      expect(logger).to have_received(:info).with(%r{coverage 1/1 LOC \(100.0%\)})
    end

    it 'is silent when computed coverage has zero LOC' do
      allow(adapter).to receive(:peek_unfiltered).and_return(tracked_file => [nil, nil])
      logger = instance_double(RSpecTracer::Logger, info: nil)

      described_class.new(
        snapshot: snapshot, report_dir: report_dir, run_metadata: {}, logger: logger
      ).generate

      expect(logger).not_to have_received(:info)
    end

    it 'accumulates skipped-example deltas onto the cumulative coverage' do
      allow(adapter).to receive(:peek_unfiltered).and_return(tracked_file => [1, nil])
      allow(registry).to receive(:ids_with_status).with(:skipped).and_return(['ex_skipped'])
      allow(engine).to receive(:merge_skipped_coverage).with(['ex_skipped']).and_return(
        tracked_file => { '0' => 2, '1' => 4 }
      )

      build_reporter.generate

      payload = JSON.parse(File.read(File.join(coverage_dir, 'coverage.json'), encoding: 'UTF-8'))
      expect(payload['RSpecTracer']['coverage'][tracked_file]).to eq([3, 4])
    end

    it 'tolerates frozen line arrays from Coverage.peek_result (Ruby 3.2+)' do
      # `::Coverage.peek_result` returns frozen line-count arrays on
      # Ruby 3.2+. Surfaced via Solidus warm-cache run with skipped
      # examples, where every cumulative-coverage file in the peek
      # output is frozen. accumulate_skipped must dup-on-write.
      frozen_line_array = [1, nil].freeze
      allow(adapter).to receive(:peek_unfiltered).and_return(tracked_file => frozen_line_array)
      allow(registry).to receive(:ids_with_status).with(:skipped).and_return(['ex_skipped'])
      allow(engine).to receive(:merge_skipped_coverage).with(['ex_skipped']).and_return(
        tracked_file => { '0' => 2, '1' => 4 }
      )

      expect { build_reporter.generate }.not_to raise_error

      payload = JSON.parse(File.read(File.join(coverage_dir, 'coverage.json'), encoding: 'UTF-8'))
      expect(payload['RSpecTracer']['coverage'][tracked_file]).to eq([3, 4])
      # Original frozen array must NOT be mutated (dup-on-write contract).
      expect(frozen_line_array).to eq([1, nil])
    end

    it 'creates a stub line array when a skipped-only file is missing from peek output' do
      allow(adapter).to receive(:peek_unfiltered).and_return({})
      allow(registry).to receive(:ids_with_status).with(:skipped).and_return(['ex_skipped'])
      allow(engine).to receive(:merge_skipped_coverage).with(['ex_skipped']).and_return(
        tracked_file => { '0' => 1 }
      )

      build_reporter.generate

      payload = JSON.parse(File.read(File.join(coverage_dir, 'coverage.json'), encoding: 'UTF-8'))
      expect(payload['RSpecTracer']['coverage'][tracked_file].first).to eq(1)
    end

    it 'returns nil and installs SimpleCov interop when simplecov? is true (array-mode coverage)' do
      allow(adapter).to receive(:peek_unfiltered_full).and_return(tracked_file => [1, 1])
      allow(RSpecTracer).to receive(:simplecov?).and_return(true)
      allow(described_class::SimpleCovInterop).to receive(:install)

      expect(build_reporter.generate).to be_nil
      expect(File).not_to exist(File.join(coverage_dir, 'coverage.json'))
      expect(described_class::SimpleCovInterop).to have_received(:install)
        .with(hash_including(tracked_file => [1, 1]))
    end

    # Hash-mode coverage (SimpleCov with `enable_coverage :branch` enabled).
    # The interop must hand SimpleCov the full {lines:, branches:} shape so
    # branch coverage survives — `peek_unfiltered` strips :branches by
    # design, so the install path uses `peek_unfiltered_full` instead. If
    # branches were lost here, every dogfooded suite would silently report
    # 0/0 branches even when SimpleCov was configured for branch coverage.
    it 'preserves the branches sub-hash when interop installs against hash-mode coverage' do
      branches = { [:if, 0, 1, 0, 1, 10] => { [:then, 1, 1, 0, 1, 5] => 3 } }
      hash_mode = { tracked_file => { lines: [1, 1], branches: branches } }
      allow(adapter).to receive(:peek_unfiltered_full).and_return(hash_mode)
      allow(RSpecTracer).to receive(:simplecov?).and_return(true)
      allow(described_class::SimpleCovInterop).to receive(:install)

      build_reporter.generate

      expect(described_class::SimpleCovInterop).to have_received(:install) do |coverage|
        expect(coverage[tracked_file]).to be_a(Hash)
        expect(coverage[tracked_file][:lines]).to eq([1, 1])
        expect(coverage[tracked_file][:branches]).to eq(branches)
      end
    end

    # Array-mode skipped-coverage attribution path: when peek returns
    # `Array<Integer|nil>` per file (default mode, no `enable_coverage
    # :branch`), the merge_lines_back `else` arm rewrites the per-path
    # entry as the mutated line array directly (no `{lines:, branches:}`
    # wrapping needed because there are no branches to preserve).
    it 'merges skipped-coverage attribution into the lines view (array-mode)' do
      array_mode = { tracked_file => [1, 0, nil] }
      allow(adapter).to receive(:peek_unfiltered_full).and_return(array_mode)
      allow(registry).to receive(:ids_with_status).with(:skipped).and_return(['ex_skipped'])
      allow(engine).to receive(:merge_skipped_coverage).with(['ex_skipped']).and_return(
        tracked_file => { 1 => 5 }
      )
      allow(RSpecTracer).to receive(:simplecov?).and_return(true)
      allow(described_class::SimpleCovInterop).to receive(:install)

      build_reporter.generate

      expect(described_class::SimpleCovInterop).to have_received(:install)
        .with(hash_including(tracked_file => [1, 5, nil]))
    end

    # Skipped-coverage attribution path: when the engine has skipped
    # examples, accumulate_skipped writes their per-line strengths
    # into a dup'd lines view; merge_lines_back syncs the (now-mutated)
    # arrays back into the full hash so SimpleCov sees both the
    # accumulated skipped lines AND the original branches. The early-
    # return on empty skipped (the common path) is exercised by the
    # two tests above; this one exercises the dup + merge round-trip.
    it 'merges skipped-coverage attribution into the lines view (hash-mode)' do
      branches = { [:if, 0, 1, 0, 1, 10] => { [:then, 1, 1, 0, 1, 5] => 3 } }
      hash_mode = { tracked_file => { lines: [1, 0, nil], branches: branches } }
      allow(adapter).to receive(:peek_unfiltered_full).and_return(hash_mode)
      allow(registry).to receive(:ids_with_status).with(:skipped).and_return(['ex_skipped'])
      allow(engine).to receive(:merge_skipped_coverage).with(['ex_skipped']).and_return(
        tracked_file => { 1 => 5, 2 => 7 }
      )
      allow(RSpecTracer).to receive(:simplecov?).and_return(true)
      allow(described_class::SimpleCovInterop).to receive(:install)

      build_reporter.generate

      expect(described_class::SimpleCovInterop).to have_received(:install) do |coverage|
        # Lines mutated: index 1 = 0 + 5 = 5; index 2 = nil treated as 0 + 7 = 7
        expect(coverage[tracked_file][:lines]).to eq([1, 5, 7])
        # Branches preserved verbatim
        expect(coverage[tracked_file][:branches]).to eq(branches)
      end
    end
  end

  describe '.merge_parallel' do
    let(:peer_a) { File.join(tmp, 'parallel_tests_1') }
    let(:peer_b) { File.join(tmp, 'parallel_tests_2') }
    let(:peer_missing) { File.join(tmp, 'parallel_tests_3') }
    let(:output_path) { File.join(coverage_dir, 'coverage.json') }

    before do
      FileUtils.mkdir_p(peer_a)
      FileUtils.mkdir_p(peer_b)
      FileUtils.mkdir_p(peer_missing)
      cov_a = { '/lib/a.rb' => [1, 2, nil], '/lib/b.rb' => [1] }
      cov_b = { '/lib/a.rb' => [4, nil, nil], '/lib/c.rb' => [9] }
      File.write(File.join(peer_a, 'coverage.json'),
                 JSON.generate(RSpecTracer: { coverage: cov_a, timestamp: 1 }))
      File.write(File.join(peer_b, 'coverage.json'),
                 JSON.generate(RSpecTracer: { coverage: cov_b, timestamp: 2 }))
    end

    it 'unions per-line strengths across peer coverage.json files' do
      described_class.merge_parallel(
        peer_paths: [peer_a, peer_b, peer_missing],
        output_path: output_path
      )

      payload = JSON.parse(File.read(output_path, encoding: 'UTF-8'))
      expect(payload['RSpecTracer']['coverage']['/lib/a.rb']).to eq([5, 2, nil])
      expect(payload['RSpecTracer']['coverage']['/lib/b.rb']).to eq([1])
      expect(payload['RSpecTracer']['coverage']['/lib/c.rb']).to eq([9])
      expect(payload['RSpecTracer']['timestamp']).to be_a(Integer)
    end

    it 'creates the output directory and emits a debug log line through the provided logger' do
      logger = instance_double(RSpecTracer::Logger, debug: nil)

      described_class.merge_parallel(
        peer_paths: [peer_a, peer_b],
        output_path: output_path,
        logger: logger
      )

      expect(File).to be_directory(coverage_dir)
      expect(logger).to have_received(:debug).with(/wrote merged coverage.json to/)
    end

    it 'skips peer paths that do not contain a coverage.json file' do
      expect do
        described_class.merge_parallel(peer_paths: [peer_missing], output_path: output_path)
      end.not_to raise_error

      payload = JSON.parse(File.read(output_path, encoding: 'UTF-8'))
      expect(payload['RSpecTracer']['coverage']).to be_empty
    end
  end

  describe 'SimpleCovInterop' do
    let(:interop) { RSpecTracer::Reporters::CoverageJsonReporter::SimpleCovInterop }

    after { interop.coverage = nil }

    it 'caches the coverage hash via .coverage' do
      cov = { '/foo.rb' => [1] }
      allow(Coverage.singleton_class).to receive(:ancestors).and_return([interop])

      interop.install(cov)

      expect(interop.coverage).to eq(cov)
    end

    it 'prepends only once even on repeated install' do
      cov = { '/foo.rb' => [1] }
      allow(Coverage.singleton_class).to receive(:ancestors).and_return([interop])
      allow(Coverage.singleton_class).to receive(:prepend)

      interop.install(cov)

      expect(Coverage.singleton_class).not_to have_received(:prepend)
    end

    it 'prepends when not yet in the ancestor chain' do
      cov = { '/foo.rb' => [1] }
      allow(Coverage.singleton_class).to receive(:ancestors).and_return([])
      allow(Coverage.singleton_class).to receive(:prepend)

      interop.install(cov)

      expect(Coverage.singleton_class).to have_received(:prepend).with(interop)
    end

    it '#result returns the cached coverage hash' do
      receiver = Object.new.tap { |o| o.singleton_class.prepend(interop) }
      interop.coverage = { '/bar.rb' => [2] }

      expect(receiver.result).to eq('/bar.rb' => [2])
    end
  end

  def build_reporter(snap: snapshot)
    described_class.new(
      snapshot: snap, report_dir: report_dir, run_metadata: {}, logger: nil
    )
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/ExampleLength, RSpec/MultipleExpectations
