# frozen_string_literal: true

require 'set'
require 'time'
require 'rspec_tracer/storage/snapshot'
require 'rspec_tracer/reporters/payload_builder'

# PayloadBuilder is the shared projection between JsonReporter and
# HtmlReporter. The spec exercises every report shape + every defensive
# branch; JsonReporter's spec now only covers its IO + delegation layer.
# rubocop:disable Metrics/MethodLength, RSpec/ExampleLength
RSpec.describe RSpecTracer::Reporters::PayloadBuilder do
  let(:empty_snapshot) { RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'empty') }
  let(:snapshot) { build_populated_snapshot }
  let(:run_metadata) do
    {
      pid: 1234,
      run_time: 4.25,
      started_at: Time.utc(2026, 4, 23, 12, 0, 0),
      cache_path: '/tmp/fake_cache',
      parallel_tests: false
    }
  end
  let(:generated_at) { Time.utc(2026, 4, 23, 12, 15, 0) }

  def build_populated_snapshot
    started = Time.utc(2026, 4, 23, 12, 0, 0)
    finished = started + 0.012
    RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'runabc').tap do |s|
      s.all_examples = {
        'ex1' => {
          full_description: 'User signs in',
          rerun_file_name: '/spec/session_spec.rb',
          rerun_line_number: 42,
          run_reason: 'Files changed',
          execution_result: {
            started_at: started, finished_at: finished, run_time: 0.012, status: :passed
          }
        },
        'ex2' => {
          full_description: 'User logs out',
          rerun_file_name: '/spec/session_spec.rb',
          rerun_line_number: 50,
          run_reason: nil,
          execution_result: nil
        },
        'ex3' => {
          full_description: 'Admin edits',
          rerun_file_name: '/spec/admin_spec.rb',
          rerun_line_number: 10,
          run_reason: 'Environment changed',
          execution_result: { started_at: nil, finished_at: nil, run_time: 0.005, status: :failed }
        }
      }
      s.duplicate_examples = {
        'dup_id' => [
          { full_description: 'dup a', rerun_file_name: '/spec/a_spec.rb', rerun_line_number: 1 },
          { full_description: 'dup b', rerun_file_name: '/spec/b_spec.rb', rerun_line_number: 2 }
        ]
      }
      s.interrupted_examples = Set.new
      s.flaky_examples = Set.new(['ex1'])
      s.failed_examples = Set.new(['ex3'])
      s.pending_examples = Set.new
      s.skipped_examples = Set.new(['ex2'])
      s.all_files = {
        '/lib/session.rb' => { file_name: '/lib/session.rb', digest: 'sha1' },
        '/lib/admin.rb' => { file_name: '/lib/admin.rb', digest: 'sha2' }
      }
      s.dependency = {
        'ex1' => Set.new(['/lib/session.rb']),
        'ex3' => Set.new(['/lib/admin.rb', '/lib/session.rb'])
      }
      s.reverse_dependency = {
        '/lib/session.rb' => Set.new(%w[ex1 ex3]),
        '/lib/admin.rb' => Set.new(['ex3'])
      }
      s.examples_coverage = {}
      s.boot_set = {}
      s.wsi_snapshot = {}
      s.env_snapshot = { 'API_KEY' => 'deadbeef' }
      s.env_dependency = { 'ex3' => ['API_KEY'] }
    end
  end

  def build_payload(snap: snapshot, metadata: run_metadata, at: generated_at)
    described_class.build(snapshot: snap, run_metadata: metadata, generated_at: at)
  end

  describe '.build convenience' do
    it 'delegates to an instance' do
      expect(described_class.build(snapshot: snapshot, run_metadata: run_metadata))
        .to include(:schema_version, :run_id, :generated_at, :summary, :reports)
    end

    it 'defaults generated_at to Time.now.utc when none supplied' do
      frozen = Time.utc(2030, 1, 1, 0, 0, 0)
      allow(Time).to receive(:now).and_return(frozen)

      payload = described_class.build(snapshot: snapshot, run_metadata: run_metadata)

      expect(payload[:generated_at]).to eq('2030-01-01T00:00:00Z')
    end

    it 'accepts nil run_metadata (coerced to empty)' do
      expect do
        described_class.build(snapshot: snapshot, run_metadata: nil)
      end.not_to raise_error
    end
  end

  describe 'envelope' do
    let(:payload) { build_payload }

    it 'stamps schema_version = 1' do
      expect(payload[:schema_version]).to eq(1)
    end

    it 'stamps run_id from the snapshot' do
      expect(payload[:run_id]).to eq('runabc')
    end

    it 'stringifies generated_at via iso8601' do
      expect(payload[:generated_at]).to eq('2026-04-23T12:15:00Z')
    end

    it 'exposes all 5 report types under :reports' do
      expect(payload[:reports].keys).to contain_exactly(
        :all_examples, :duplicate_examples, :flaky_examples,
        :examples_dependency, :files_dependency
      )
    end
  end

  describe 'summary block' do
    let(:summary) { build_payload[:summary] }

    it 'counts total examples' do
      expect(summary[:total_examples]).to eq(3)
    end

    it 'counts passed via execution_result.status' do
      expect(summary[:passed_examples]).to eq(1)
    end

    it 'forwards failed/pending/skipped/flaky/interrupted/duplicate counts' do
      expect(summary).to include(
        failed_examples: 1, pending_examples: 0,
        skipped_examples: 1, flaky_examples: 1,
        interrupted_examples: 0, duplicate_examples: 1
      )
    end

    it 'reports tracked_env_keys from env_snapshot' do
      expect(summary[:tracked_env_keys]).to eq(1)
    end

    it 'forwards run_time + pid + parallel_tests from run_metadata' do
      expect(summary).to include(run_time: 4.25, pid: 1234, parallel_tests: false)
    end

    it 'stringifies started_at via iso8601' do
      expect(summary[:started_at]).to eq('2026-04-23T12:00:00Z')
    end

    it 'tolerates run_metadata without any keys' do
      expect(build_payload(metadata: {})[:summary][:run_time]).to be_nil
    end

    it 'tolerates a nil env_snapshot (defensive)' do
      snap = build_populated_snapshot
      snap.env_snapshot = nil

      expect(build_payload(snap: snap)[:summary][:tracked_env_keys]).to eq(0)
    end

    it 'coerces parallel_tests non-true values to false' do
      md = run_metadata.merge(parallel_tests: 'truthy string')

      expect(build_payload(metadata: md)[:summary][:parallel_tests]).to be(false)
    end
  end

  describe 'all_examples report' do
    let(:entries) { build_payload[:reports][:all_examples] }

    it 'emits one entry per example' do
      expect(entries.map { |e| e[:id] }).to contain_exactly('ex1', 'ex2', 'ex3')
    end

    it 'picks full_description when present' do
      expect(entries.find { |e| e[:id] == 'ex1' }[:description]).to eq('User signs in')
    end

    it 'surfaces run_reason' do
      expect(entries.find { |e| e[:id] == 'ex3' }[:run_reason]).to eq('Environment changed')
    end

    it 'stringifies execution_result.started_at via iso8601' do
      ex1 = entries.find { |e| e[:id] == 'ex1' }

      expect(ex1[:execution_result][:started_at]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    end

    it 'yields nil execution_result when the example has none' do
      expect(entries.find { |e| e[:id] == 'ex2' }[:execution_result]).to be_nil
    end

    it 'strips leading slash + appends :line in location' do
      expect(entries.find { |e| e[:id] == 'ex1' }[:location]).to eq('spec/session_spec.rb:42')
    end

    it 'classifies status via the priority ladder' do
      statuses = %w[ex1 ex2 ex3].map { |id| entries.find { |e| e[:id] == id }[:status] }

      expect(statuses).to eq(%w[flaky skipped failed])
    end

    it 'coerces non-Hash meta entries to defaults without raising' do
      snap = build_populated_snapshot
      snap.all_examples = { 'ex_bad' => 'not a hash' }
      bad = build_payload(snap: snap)[:reports][:all_examples].first

      expect(bad).to include(id: 'ex_bad', description: nil, location: nil)
    end

    it 'falls back to description when full_description is absent' do
      snap = build_populated_snapshot
      snap.all_examples = { 'ex_desc' => { description: 'just short' } }

      expect(build_payload(snap: snap)[:reports][:all_examples].first[:description])
        .to eq('just short')
    end

    it 'returns status unknown when execution_result is not a Hash' do
      snap = build_populated_snapshot
      snap.all_examples = { 'ex_noexec' => { execution_result: 'not a hash' } }
      snap.failed_examples = Set.new
      snap.flaky_examples = Set.new
      snap.pending_examples = Set.new
      snap.skipped_examples = Set.new
      snap.interrupted_examples = Set.new

      expect(build_payload(snap: snap)[:reports][:all_examples].first[:status])
        .to eq('unknown')
    end

    it 'classifies status interrupted when in interrupted_examples' do
      snap = build_populated_snapshot
      snap.interrupted_examples = Set.new(['ex1'])
      ex1 = build_payload(snap: snap)[:reports][:all_examples].find { |e| e[:id] == 'ex1' }

      expect(ex1[:status]).to eq('interrupted')
    end

    it 'classifies status pending when in pending_examples' do
      snap = build_populated_snapshot
      snap.flaky_examples = Set.new
      snap.pending_examples = Set.new(['ex1'])
      ex1 = build_payload(snap: snap)[:reports][:all_examples].find { |e| e[:id] == 'ex1' }

      expect(ex1[:status]).to eq('pending')
    end

    it 'classifies status from execution_result when no set claims it' do
      snap = build_populated_snapshot
      snap.flaky_examples = Set.new
      snap.failed_examples = Set.new
      snap.skipped_examples = Set.new
      ex1 = build_payload(snap: snap)[:reports][:all_examples].find { |e| e[:id] == 'ex1' }

      expect(ex1[:status]).to eq('passed')
    end

    it 'returns nil location when neither rerun_file_name nor file_name present' do
      snap = build_populated_snapshot
      snap.all_examples = { 'ex_no_file' => { full_description: 'x' } }

      expect(build_payload(snap: snap)[:reports][:all_examples].first[:location]).to be_nil
    end

    it 'returns location without trailing colon when line is absent' do
      snap = build_populated_snapshot
      snap.all_examples = { 'ex_no_line' => { rerun_file_name: '/spec/only_spec.rb' } }

      expect(build_payload(snap: snap)[:reports][:all_examples].first[:location])
        .to eq('spec/only_spec.rb')
    end

    it 'stringifies a String time argument as-is' do
      snap = build_populated_snapshot
      snap.all_examples = {
        'ex_str_time' => {
          execution_result: {
            started_at: '2026-01-01T00:00:00Z', finished_at: nil, run_time: 0.0, status: :passed
          }
        }
      }
      entry = build_payload(snap: snap)[:reports][:all_examples].first

      expect(entry[:execution_result][:started_at]).to eq('2026-01-01T00:00:00Z')
    end

    it 'stringifies an object without iso8601 via to_s' do
      snap = build_populated_snapshot
      snap.all_examples = {
        'ex_weird_time' => {
          execution_result: {
            started_at: 42, finished_at: nil, run_time: 0.0, status: :passed
          }
        }
      }
      entry = build_payload(snap: snap)[:reports][:all_examples].first

      expect(entry[:execution_result][:started_at]).to eq('42')
    end

    it 'returns nil execution_result when result is not a Hash' do
      snap = build_populated_snapshot
      snap.all_examples = { 'ex_bogus' => { execution_result: 'garbage' } }
      entry = build_payload(snap: snap)[:reports][:all_examples].first

      expect(entry[:execution_result]).to be_nil
    end

    it 'defaults execution_result status to unknown when missing' do
      snap = build_populated_snapshot
      snap.all_examples = { 'ex_no_status' => { execution_result: { run_time: 0.1 } } }
      snap.flaky_examples = Set.new
      snap.failed_examples = Set.new
      snap.pending_examples = Set.new
      snap.skipped_examples = Set.new
      snap.interrupted_examples = Set.new
      entry = build_payload(snap: snap)[:reports][:all_examples].first

      expect(entry[:execution_result][:status]).to eq('unknown')
    end

    it 'counts passed via a string-keyed execution_result (defensive)' do
      snap = build_populated_snapshot
      snap.all_examples = {
        'ex_str' => { 'execution_result' => { 'status' => 'passed' } }
      }

      expect(build_payload(snap: snap)[:summary][:passed_examples]).to eq(1)
    end
  end

  describe 'duplicate_examples report' do
    let(:entries) { build_payload[:reports][:duplicate_examples] }

    it 'emits one entry per duplicate id' do
      expect(entries.map { |e| e[:id] }).to eq(['dup_id'])
    end

    it 'counts the entries per duplicate id' do
      expect(entries.first[:count]).to eq(2)
    end

    it 'flattens each duplicate entry into { description, location }' do
      expect(entries.first[:entries].map { |e| e[:description] })
        .to contain_exactly('dup a', 'dup b')
    end

    it 'coerces non-Array entries to empty list' do
      snap = build_populated_snapshot
      snap.duplicate_examples = { 'weird' => 'not an array' }
      dup = build_payload(snap: snap)[:reports][:duplicate_examples].first

      expect(dup).to eq(id: 'weird', count: 0, entries: [])
    end

    it 'coerces non-Hash entry items to defaults' do
      snap = build_populated_snapshot
      snap.duplicate_examples = { 'dup' => ['not a hash'] }
      dup = build_payload(snap: snap)[:reports][:duplicate_examples].first

      expect(dup[:entries].first).to eq(description: nil, location: nil)
    end
  end

  describe 'flaky_examples report' do
    let(:entries) { build_payload[:reports][:flaky_examples] }

    it 'emits one entry per flaky id' do
      expect(entries.map { |e| e[:id] }).to eq(['ex1'])
    end

    it 'projects description + location from all_examples' do
      expect(entries.first).to include(
        description: 'User signs in',
        location: 'spec/session_spec.rb:42'
      )
    end

    it 'tolerates a flaky id missing from all_examples (cache drift)' do
      snap = build_populated_snapshot
      snap.flaky_examples = Set.new(['ghost_id'])
      ghost = build_payload(snap: snap)[:reports][:flaky_examples].find { |e| e[:id] == 'ghost_id' }

      expect(ghost).to include(id: 'ghost_id', description: nil, location: nil)
    end
  end

  describe 'examples_dependency report' do
    let(:entries) { build_payload[:reports][:examples_dependency] }

    it 'emits an entry per example_id in dependency' do
      expect(entries.map { |e| e[:example_id] }).to contain_exactly('ex1', 'ex3')
    end

    it 'sorts entries by example_id for determinism' do
      expect(entries.map { |e| e[:example_id] }).to eq(%w[ex1 ex3])
    end

    it 'projects env_dependency into env_keys' do
      ex3 = entries.find { |e| e[:example_id] == 'ex3' }

      expect(ex3[:env_keys]).to eq(['API_KEY'])
    end

    it 'emits empty env_keys for an example not in env_dependency' do
      ex1 = entries.find { |e| e[:example_id] == 'ex1' }

      expect(ex1[:env_keys]).to eq([])
    end

    it 'sorts files per-example' do
      ex3 = entries.find { |e| e[:example_id] == 'ex3' }

      expect(ex3[:files]).to eq(['/lib/admin.rb', '/lib/session.rb'])
    end

    it 'tolerates nil env_dependency on the snapshot' do
      snap = build_populated_snapshot
      snap.env_dependency = nil
      entries = build_payload(snap: snap)[:reports][:examples_dependency]
      ex3 = entries.find { |e| e[:example_id] == 'ex3' }

      expect(ex3[:env_keys]).to eq([])
    end

    it 'tolerates a non-Set dependency value (graceful for custom callers)' do
      snap = build_populated_snapshot
      snap.dependency = { 'ex_plain' => ['/lib/x.rb'] }
      entry = build_payload(snap: snap)[:reports][:examples_dependency].first

      expect(entry[:files]).to eq(['/lib/x.rb'])
    end
  end

  describe 'files_dependency report' do
    let(:entries) { build_payload[:reports][:files_dependency] }

    it 'emits one entry per file in reverse_dependency' do
      expect(entries.map { |e| e[:file_name] })
        .to contain_exactly('/lib/session.rb', '/lib/admin.rb')
    end

    it 'counts examples per file' do
      session = entries.find { |e| e[:file_name] == '/lib/session.rb' }

      expect(session[:example_count]).to eq(2)
    end

    it 'sorts by -example_count then file_name' do
      expect(entries.map { |e| e[:file_name] }).to eq(['/lib/session.rb', '/lib/admin.rb'])
    end

    it 'aggregates spec_files by count descending' do
      session = entries.find { |e| e[:file_name] == '/lib/session.rb' }

      expect(session[:spec_files])
        .to eq('/spec/session_spec.rb' => 1, '/spec/admin_spec.rb' => 1)
    end

    it 'falls back to file_name when rerun_file_name is missing' do
      snap = build_populated_snapshot
      snap.all_examples = { 'exx' => { file_name: '/spec/fallback_spec.rb' } }
      snap.reverse_dependency = { '/lib/whatever.rb' => Set.new(['exx']) }

      expect(build_payload(snap: snap)[:reports][:files_dependency].first[:spec_files])
        .to eq('/spec/fallback_spec.rb' => 1)
    end

    it 'skips ids whose meta is not a Hash' do
      snap = build_populated_snapshot
      snap.all_examples = { 'ex_bad' => 'not a hash' }
      snap.reverse_dependency = { '/lib/only.rb' => Set.new(['ex_bad']) }

      expect(build_payload(snap: snap)[:reports][:files_dependency].first[:spec_files])
        .to eq({})
    end

    it 'skips ids whose meta has empty spec filename' do
      snap = build_populated_snapshot
      snap.all_examples = { 'exblank' => { rerun_file_name: '' } }
      snap.reverse_dependency = { '/lib/only.rb' => Set.new(['exblank']) }

      expect(build_payload(snap: snap)[:reports][:files_dependency].first[:spec_files])
        .to eq({})
    end

    it 'tolerates a non-Set reverse_dependency value (Array form)' do
      snap = build_populated_snapshot
      snap.reverse_dependency = { '/lib/plain.rb' => ['ex1'] }

      expect(build_payload(snap: snap)[:reports][:files_dependency].first[:example_count])
        .to eq(1)
    end
  end

  describe 'SCHEMA_VERSION constant' do
    it 'is pinned to 1' do
      expect(described_class::SCHEMA_VERSION).to eq(1)
    end

    it 'is frozen' do
      expect(described_class::SCHEMA_VERSION).to be_frozen
    end
  end
end
# rubocop:enable Metrics/MethodLength, RSpec/ExampleLength
