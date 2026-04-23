# frozen_string_literal: true

require 'fileutils'
require 'set'
require 'tmpdir'
require 'time'
require 'rspec_tracer/storage/snapshot'
require 'rspec_tracer/reporters/html_reporter'

require_relative '../contracts/reporter'

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/MultipleExpectations
# rubocop:disable RSpec/ExampleLength
RSpec.describe RSpecTracer::Reporters::HtmlReporter do
  let(:tmp) { Dir.mktmpdir }
  let(:empty_snapshot) { RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'empty') }
  let(:snapshot) { build_populated_snapshot }
  let(:run_metadata) do
    {
      pid: 1234,
      run_time: 4.25,
      started_at: Time.utc(2026, 4, 23, 12, 0, 0),
      parallel_tests: false
    }
  end
  let(:report_dir) { File.join(tmp, 'rspec_tracer_report') }
  let(:reporter_class) { described_class }
  let(:generated_at) { Time.utc(2026, 4, 23, 12, 15, 0) }

  after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

  def minimal_template
    marker = '<!-- RSPEC_TRACER_FALLBACK -->'
    payload = '<script id="report-data" type="application/json">{}</script>'
    "<!doctype html><html><body>#{marker}#{payload}</body></html>"
  end

  def build_populated_snapshot
    RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'runhtml').tap do |s|
      s.all_examples = {
        'ex1' => {
          full_description: 'User signs in <script>alert(1)</script>',
          rerun_file_name: '/spec/session_spec.rb',
          rerun_line_number: 42,
          run_reason: 'Files changed',
          execution_result: { run_time: 0.012, status: :passed }
        },
        'ex2' => {
          full_description: 'User logs out',
          rerun_file_name: '/spec/session_spec.rb',
          rerun_line_number: 50,
          execution_result: { run_time: 0.0005, status: :failed }
        }
      }
      s.duplicate_examples = {}
      s.flaky_examples = Set.new(['ex1'])
      s.failed_examples = Set.new(['ex2'])
      s.all_files = { '/lib/session.rb' => { file_name: '/lib/session.rb' } }
      s.dependency = { 'ex1' => Set.new(['/lib/session.rb']) }
      s.reverse_dependency = { '/lib/session.rb' => Set.new(['ex1']) }
      s.env_snapshot = { 'API_KEY' => 'hash' }
      s.env_dependency = { 'ex1' => ['API_KEY'] }
    end
  end

  def build_reporter(snap: snapshot, metadata: run_metadata, **opts)
    described_class.new(
      snapshot: snap, report_dir: report_dir, run_metadata: metadata,
      logger: nil, generated_at: generated_at, **opts
    )
  end

  def output_path
    File.join(report_dir, 'index.html')
  end

  it_behaves_like 'a Reporters::Base'

  describe '#generate (no-op path)' do
    it 'returns nil when the snapshot has no tracked examples' do
      expect(build_reporter(snap: empty_snapshot).generate).to be_nil
    end

    it 'does not write index.html on no-op' do
      build_reporter(snap: empty_snapshot).generate

      expect(File).not_to exist(output_path)
    end
  end

  describe '#generate (populated path)' do
    it 'creates report_dir if missing' do
      build_reporter.generate

      expect(File).to be_directory(report_dir)
    end

    it 'writes index.html under report_dir' do
      build_reporter.generate

      expect(File).to exist(output_path)
    end

    it 'returns the written path' do
      expect(build_reporter.generate).to eq(output_path)
    end

    it 'copies the bundled assets directory' do
      build_reporter.generate

      expect(File).to be_directory(File.join(report_dir, 'assets'))
    end

    it 'copies the compiled JS bundle' do
      build_reporter.generate

      expect(File).to exist(File.join(report_dir, 'assets', 'index.js'))
    end

    it 'copies the compiled CSS bundle' do
      build_reporter.generate

      expect(File).to exist(File.join(report_dir, 'assets', 'index.css'))
    end

    it 'logs a debug line through the provided logger' do
      logger = instance_double(RSpecTracer::Logger, debug: nil, warn: nil)
      described_class.new(
        snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata,
        logger: logger, generated_at: generated_at
      ).generate

      expect(logger).to have_received(:debug).with(/wrote HTML report/)
    end
  end

  describe 'payload embedding' do
    before { build_reporter.generate }

    let(:html) { File.read(output_path) }

    it 'replaces the <script id="report-data"> body with the payload JSON' do
      expect(html).to match(%r{<script id="report-data" type="application/json">\{.*\}</script>})
    end

    it 'embeds the run_id into the payload' do
      expect(html).to include('"run_id":"runhtml"')
    end

    it 'JSON-escapes angle brackets so embedded HTML cannot break out of <script>' do
      expect(html).not_to include('<script>alert(1)</script>')
      expect(html).to include('\\u003cscript\\u003ealert(1)\\u003c/script\\u003e')
    end

    it 'JSON-escapes ampersands as \\u0026' do
      snap = build_populated_snapshot
      snap.all_examples = {
        'ex_amp' => { full_description: 'A & B', rerun_file_name: '/spec/x.rb', rerun_line_number: 1 }
      }
      described_class.new(
        snapshot: snap, report_dir: report_dir, run_metadata: {}, logger: nil,
        generated_at: generated_at
      ).generate

      expect(File.read(output_path)).to include('\\u0026')
    end
  end

  describe 'fallback rendering' do
    before { build_reporter.generate }

    let(:html) { File.read(output_path) }

    it 'replaces the fallback marker with actual tables' do
      expect(html).not_to include('<!-- RSPEC_TRACER_FALLBACK -->')
      expect(html).to include('id="fallback"')
    end

    it 'renders the All Examples fallback section' do
      expect(html).to include('id="fallback-all-examples"')
      expect(html).to include('User logs out')
    end

    it 'HTML-escapes user-content in the fallback so <script> cannot execute' do
      expect(html).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
    end

    it 'renders the Flaky Examples section only when non-empty' do
      expect(html).to include('id="fallback-flaky-examples"')
    end

    it 'renders the Examples Dependency section with env keys prefix' do
      expect(html).to include('id="fallback-examples-dependency"')
      expect(html).to include('env:API_KEY')
    end

    it 'renders the Files Dependency section with spec file counts' do
      expect(html).to include('id="fallback-files-dependency"')
      expect(html).to include('/spec/session_spec.rb (1)')
    end

    it 'omits the Duplicate Examples section when the snapshot has none' do
      expect(html).not_to include('id="fallback-duplicate-examples"')
    end

    it 'omits the Flaky Examples section when none are flaky' do
      snap = build_populated_snapshot
      snap.flaky_examples = Set.new
      described_class.new(
        snapshot: snap, report_dir: report_dir, run_metadata: {}, logger: nil,
        generated_at: generated_at
      ).generate

      expect(File.read(output_path)).not_to include('id="fallback-flaky-examples"')
    end

    it 'renders the Duplicate Examples section when duplicates exist' do
      snap = build_populated_snapshot
      snap.duplicate_examples = {
        'dup' => [
          { full_description: 'a dup', rerun_file_name: '/s.rb', rerun_line_number: 1 },
          { full_description: 'b dup', rerun_file_name: '/s.rb', rerun_line_number: 2 }
        ]
      }
      described_class.new(
        snapshot: snap, report_dir: report_dir, run_metadata: {}, logger: nil,
        generated_at: generated_at
      ).generate

      expect(File.read(output_path)).to include('id="fallback-duplicate-examples"')
    end

    it 'prints "No rows." when a section is empty' do
      snap = build_populated_snapshot
      snap.all_examples = { 'placeholder' => { full_description: 'solo' } }
      snap.dependency = {}
      snap.reverse_dependency = {}
      described_class.new(
        snapshot: snap, report_dir: report_dir, run_metadata: {}, logger: nil,
        generated_at: generated_at
      ).generate

      expect(File.read(output_path)).to include('No rows.')
    end
  end

  describe 'duration formatting in fallback' do
    it 'formats sub-millisecond durations in us' do
      build_reporter.generate

      expect(File.read(output_path)).to match(/\d+ us/)
    end

    it 'formats millisecond durations' do
      build_reporter.generate

      expect(File.read(output_path)).to include('12.0 ms')
    end

    it 'formats second durations' do
      snap = build_populated_snapshot
      snap.all_examples['ex1'][:execution_result][:run_time] = 1.25

      described_class.new(
        snapshot: snap, report_dir: report_dir, run_metadata: {}, logger: nil,
        generated_at: generated_at
      ).generate

      expect(File.read(output_path)).to include('1.250 s')
    end

    it 'emits empty string when run_time is non-numeric' do
      snap = build_populated_snapshot
      snap.all_examples['ex1'][:execution_result][:run_time] = nil
      described_class.new(
        snapshot: snap, report_dir: report_dir, run_metadata: {}, logger: nil,
        generated_at: generated_at
      ).generate
      html = File.read(output_path)

      expect(html).to match(%r{<td></td>\s*<td></td>\s*</tr>}m).or(include('<td></td>'))
    end
  end

  describe 'graceful degradation' do
    it 'returns nil and logs a warning when the dist template is missing' do
      missing_dir = File.join(tmp, 'missing_dist')
      logger = instance_double(RSpecTracer::Logger, warn: nil, debug: nil)
      reporter = described_class.new(
        snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata,
        logger: logger, dist_dir: missing_dir, generated_at: generated_at
      )

      result = reporter.generate

      expect(result).to be_nil
      expect(logger).to have_received(:warn).with(/HTML template missing/)
    end

    it 'does not write index.html when the dist template is missing' do
      missing_dir = File.join(tmp, 'missing_dist')
      described_class.new(
        snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata,
        logger: nil, dist_dir: missing_dir, generated_at: generated_at
      ).generate

      expect(File).not_to exist(output_path)
    end
  end

  describe 'dist_dir option' do
    it 'uses a custom dist_dir when provided' do
      custom = File.join(tmp, 'custom_dist')
      FileUtils.mkdir_p(File.join(custom, 'assets'))
      File.write(File.join(custom, 'index.html'), minimal_template)
      File.write(File.join(custom, 'assets', 'index.js'), '/* fake */')

      described_class.new(
        snapshot: snapshot, report_dir: report_dir, run_metadata: {}, logger: nil,
        dist_dir: custom, generated_at: generated_at
      ).generate

      expect(File.read(output_path)).to include('"run_id":"runhtml"')
    end

    it 'falls back to the committed DIST_DIR constant when no option supplied' do
      described_class.new(
        snapshot: snapshot, report_dir: report_dir, run_metadata: {}, logger: nil,
        generated_at: generated_at
      ).generate

      expect(File).to exist(File.join(report_dir, 'assets', 'index.js'))
    end

    it 'skips asset copy when dist/assets is absent' do
      custom = File.join(tmp, 'custom_noassets')
      FileUtils.mkdir_p(custom)
      File.write(File.join(custom, 'index.html'), minimal_template)

      described_class.new(
        snapshot: snapshot, report_dir: report_dir, run_metadata: {}, logger: nil,
        dist_dir: custom, generated_at: generated_at
      ).generate

      expect(File).not_to be_directory(File.join(report_dir, 'assets'))
    end
  end

  describe 'visual regression golden' do
    let(:golden_path) { File.expand_path('../fixtures/golden/html_reporter/index.html', __dir__) }
    let(:golden_snapshot) do
      RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'goldfix').tap do |s|
        s.all_examples = {
          'gx1' => {
            full_description: 'Golden example one',
            rerun_file_name: '/spec/gold_spec.rb',
            rerun_line_number: 7,
            run_reason: 'Files changed',
            execution_result: { run_time: 0.05, status: :passed }
          },
          'gx2' => {
            full_description: 'Golden example two',
            rerun_file_name: '/spec/gold_spec.rb',
            rerun_line_number: 13,
            run_reason: nil,
            execution_result: nil
          }
        }
        s.duplicate_examples = {}
        s.flaky_examples = Set.new
        s.failed_examples = Set.new
        s.skipped_examples = Set.new(['gx2'])
        s.all_files = { '/lib/gold.rb' => { file_name: '/lib/gold.rb' } }
        s.dependency = { 'gx1' => Set.new(['/lib/gold.rb']) }
        s.reverse_dependency = { '/lib/gold.rb' => Set.new(['gx1']) }
      end
    end
    let(:golden_metadata) do
      { pid: 99, run_time: 1.5, started_at: Time.utc(2026, 1, 1, 0, 0, 0), parallel_tests: false }
    end
    let(:golden_generated_at) { Time.utc(2026, 1, 1, 0, 15, 0) }

    it 'matches the committed golden byte-for-byte' do
      skip "golden fixture missing at #{golden_path}" unless File.exist?(golden_path)

      described_class.new(
        snapshot: golden_snapshot, report_dir: report_dir, run_metadata: golden_metadata,
        logger: nil, generated_at: golden_generated_at
      ).generate

      expect(File.read(output_path)).to eq(File.read(golden_path))
    end
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/MultipleExpectations
# rubocop:enable RSpec/ExampleLength
