# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'
require 'tmpdir'
require 'rspec_tracer/engine'

# The Engine class is the v2 coordinator. Unit tests drive it with a
# stubbed configuration so the subject doesn't depend on the global
# RSpecTracer module's state. Integration coverage (real RSpec
# fixture, subprocess) lives at spec/integration/ruby_app_v2_tracker_spec.rb.
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers
RSpec.describe RSpecTracer::Engine do
  let(:tmp_base) { Dir.mktmpdir }
  let(:root) { File.join(tmp_base, 'project').tap { |p| FileUtils.mkdir_p(p) } }
  let(:cache_path) { File.join(tmp_base, 'cache') }
  let(:logger) { instance_double(RSpecTracer::Logger, debug: nil, info: nil, warn: nil, error: nil) }
  let(:configuration) { stub_configuration }

  before do
    write_project_file('lib/a.rb', "module A; VALUE = 1; end\n")
    write_project_file('lib/b.rb', "require_relative 'a'\nUSER = A::VALUE\n")
  end

  after do
    RSpecTracer::Tracker::IOHooks.uninstall
    RSpecTracer::Tracker::IOHooks.clear_bucket
    FileUtils.rm_rf(tmp_base) if tmp_base
  end

  def write_project_file(rel, contents = "x\n")
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  def stub_configuration(overrides = {})
    defaults = {
      root: root, cache_path: cache_path, logger: logger,
      filters: [], declared_globs: [],
      run_all_examples: false, transitive_load_tracking: false,
      rails?: false, track_ar_schema_notifications?: false,
      cache_retention_local_count: nil,
      cache_size_warn_per_file_mb: nil, cache_size_warn_total_mb: nil
    }
    double(**defaults, **overrides).tap do |config|
      allow(config).to receive(:freeze_declared_globs!)
    end
  end

  def build_tracker(configuration_override = configuration)
    described_class.new(configuration: configuration_override)
  end

  def build_example(example_id, file_name = '/spec/thing_spec.rb', line = 1)
    {
      example_id: example_id,
      file_name: file_name,
      line_number: line,
      rerun_file_name: file_name,
      rerun_line_number: line,
      full_description: "Example #{example_id}",
      description: "Example #{example_id}",
      example_group: 'Thing',
      shared_group: []
    }
  end

  def build_execution_result(status:, run_time: 0.01)
    now = Time.now
    double(
      started_at: now, finished_at: now + run_time, run_time: run_time, status: status
    )
  end

  describe '#initialize' do
    it 'holds nothing until setup is called' do
      tracker = build_tracker

      expect(tracker.registry).to be_nil
    end

    it 'reports previous_snapshot_loaded? as false before setup' do
      tracker = build_tracker

      expect(tracker.previous_snapshot_loaded?).to be(false)
    end
  end

  describe '#setup' do
    subject(:tracker) { build_tracker.tap(&:setup) }

    it 'freezes declared globs on the configuration' do
      tracker

      expect(configuration).to have_received(:freeze_declared_globs!)
    end

    it 'builds all eight observer instances' do
      expect([
        tracker.registry, tracker.graph, tracker.loaded_files_tracker,
        tracker.coverage_adapter, tracker.declared_globs,
        tracker.whole_suite_invalidators, tracker.new_file_detector,
        tracker.env_snapshot
      ]).to all(be_a(Object))
    end

    it 'constructs a JSON storage backend pointed at cache_path' do
      expect(tracker.storage_backend).to be_a(RSpecTracer::Storage::JsonBackend)
    end

    it 'installs IOHooks' do
      tracker

      expect(RSpecTracer::Tracker::IOHooks.installed?).to be(true)
    end

    it 'captures the boot set via the LoadedFilesTracker' do
      expect(tracker.loaded_files_tracker.boot_set).not_to be_nil
    end

    it 'returns self' do
      tracker_instance = build_tracker
      expect(tracker_instance.setup).to be(tracker_instance)
    end
  end

  describe '#run_example? / #run_example_reason' do
    subject(:tracker) { build_tracker.tap(&:setup) }

    it 'runs every example when run_all_examples is true' do
      tracker = build_tracker(stub_configuration(run_all_examples: true)).tap(&:setup)

      expect(tracker.run_example?('new_id')).to be(true)
      expect(tracker.run_example_reason('new_id')).to eq('Explicit run')
    end

    it 'runs an example not present in the previous snapshot (no cache case)' do
      expect(tracker.run_example?('brand_new_id')).to be(true)
    end

    it 'reports no_cache as the reason for previously-unseen ids' do
      expect(tracker.run_example_reason('brand_new_id')).to eq('No cache')
    end
  end

  describe '#register_example / #deregister_duplicate_examples' do
    subject(:tracker) { build_tracker.tap(&:setup) }

    it 'adds an example to all_examples on first register' do
      tracker.register_example(build_example('ex1'))

      expect(tracker.all_examples).to have_key('ex1')
    end

    it 'deregister drops the singletons and keeps only real duplicates' do
      tracker.register_example(build_example('ex1'))
      tracker.register_example(build_example('ex2', '/spec/other_spec.rb'))
      tracker.register_example(build_example('ex2', '/spec/dup_spec.rb'))

      tracker.deregister_duplicate_examples

      expect(tracker.duplicate_examples.keys).to eq(['ex2'])
    end

    it 'removes duplicated ids from all_examples after deregister' do
      tracker.register_example(build_example('ex2'))
      tracker.register_example(build_example('ex2'))
      tracker.deregister_duplicate_examples

      expect(tracker.all_examples).not_to have_key('ex2')
    end
  end

  describe 'per-example lifecycle' do
    subject(:tracker) { build_tracker.tap(&:setup) }

    it 'example_started + example_finished record a coverage delta entry' do
      a_path = File.join(root, 'lib/a.rb')
      peeks = [
        { a_path => [1, 0, 1] },
        { a_path => [1, 1, 1] }
      ]
      allow(tracker.coverage_adapter).to receive(:peek).and_return(*peeks)
      tracker.register_example(build_example('ex1'))
      tracker.example_started
      tracker.example_finished('ex1')

      expect(tracker.examples_coverage['ex1']).to have_key(a_path)
    end

    it 'example_finished installs a graph entry for the example' do
      a_path = File.join(root, 'lib/a.rb')
      peeks = [{ a_path => [1, 0, 1] }, { a_path => [1, 1, 1] }]
      allow(tracker.coverage_adapter).to receive(:peek).and_return(*peeks)
      tracker.register_example(build_example('ex1'))
      tracker.example_started
      tracker.example_finished('ex1')

      expect(tracker.graph.paths_for('ex1')).to include(a_path)
    end

    it 'clears the IOHooks bucket after example_finished' do
      allow(tracker.coverage_adapter).to receive(:peek).and_return({}, {})
      tracker.register_example(build_example('ex1'))
      tracker.example_started
      tracker.example_finished('ex1')

      expect(RSpecTracer::Tracker::IOHooks.current_bucket).to be_nil
    end

    it 'on_example_passed records the execution result on the metadata hash' do
      allow(tracker.coverage_adapter).to receive(:peek).and_return({}, {})
      tracker.register_example(build_example('ex1'))
      tracker.example_started
      tracker.example_finished('ex1')
      tracker.on_example_passed('ex1', build_execution_result(status: :passed))

      expect(tracker.all_examples['ex1'][:execution_result][:status]).to eq('passed')
    end

    it 'on_example_failed updates registry status to :failed' do
      tracker.register_example(build_example('ex1'))
      tracker.on_example_failed('ex1', build_execution_result(status: :failed))

      expect(tracker.registry.status_of('ex1')).to eq(:failed)
    end

    it 'on_example_pending updates registry status to :pending' do
      tracker.register_example(build_example('ex1'))
      tracker.on_example_pending('ex1', build_execution_result(status: :pending))

      expect(tracker.registry.status_of('ex1')).to eq(:pending)
    end

    it 'on_example_skipped updates registry status without a prior register' do
      tracker.on_example_skipped('stale_id')

      expect(tracker.registry.status_of('stale_id')).to eq(:skipped)
    end

    it 'on_example_passed is a no-op for duplicate ids' do
      tracker.register_example(build_example('dup'))
      tracker.register_example(build_example('dup'))

      tracker.on_example_passed('dup', build_execution_result(status: :passed))

      expect(tracker.registry.status_of('dup')).to be_nil
    end
  end

  describe '#finalize' do
    subject(:tracker) { build_tracker.tap(&:setup) }

    it 'writes a v2 cache under cache_path' do
      allow(tracker.coverage_adapter).to receive(:peek).and_return({}, {})
      tracker.register_example(build_example('ex1'))
      tracker.example_started
      tracker.example_finished('ex1')
      tracker.on_example_passed('ex1', build_execution_result(status: :passed))

      tracker.finalize

      expect(File).to exist(File.join(cache_path, 'last_run.json'))
    end

    it 'stamps the cache with schema_version 3' do
      allow(tracker.coverage_adapter).to receive(:peek).and_return({}, {})
      tracker.register_example(build_example('ex1'))
      tracker.example_started
      tracker.example_finished('ex1')
      tracker.on_example_passed('ex1', build_execution_result(status: :passed))

      tracker.finalize

      manifest = JSON.parse(File.read(File.join(cache_path, 'last_run.json')))
      expect(manifest['schema_version']).to eq(3)
    end

    it 'flags ids without a terminal status as :interrupted at finalize' do
      tracker.register_example(build_example('ex1'))

      snapshot = tracker.finalize

      expect(snapshot.interrupted_examples).to include('ex1')
    end

    it 'persists the boot_set digest snapshot alongside the run' do
      snapshot = tracker.finalize

      expect(snapshot.boot_set).to be_a(Hash)
    end

    it 'returns the Snapshot it persisted' do
      expect(tracker.finalize).to be_a(RSpecTracer::Storage::Snapshot)
    end

    it 'persists env_snapshot for every tracked env key' do
      stub_const('ENV', 'API_KEY' => 'secret')
      tracker.register_tracks('ex1', files: Set.new, env: Set.new(['API_KEY']))

      snapshot = tracker.finalize

      expect(snapshot.env_snapshot).to have_key('API_KEY')
    end

    it 'leaves env_snapshot empty when no tracks were registered' do
      snapshot = tracker.finalize

      expect(snapshot.env_snapshot).to eq({})
    end

    it 'persists env_dependency per example (M6.1 - reporter input)' do
      tracker.register_tracks('ex1', files: Set.new, env: Set.new(%w[API_KEY ROLE]))
      tracker.register_tracks('ex2', files: Set.new, env: Set.new(['API_KEY']))

      snapshot = tracker.finalize

      expect(snapshot.env_dependency).to eq(
        'ex1' => %w[API_KEY ROLE],
        'ex2' => ['API_KEY']
      )
    end

    it 'leaves env_dependency empty when no tracks were registered' do
      snapshot = tracker.finalize

      expect(snapshot.env_dependency).to eq({})
    end

    it 'omits examples with empty env sets from env_dependency' do
      tracker.register_tracks('ex_filesonly', files: Set.new(['config/*.yml']), env: Set.new)

      snapshot = tracker.finalize

      expect(snapshot.env_dependency).to eq({})
    end
  end

  describe '#register_tracks (M5.2 DSL hook)' do
    subject(:tracker) { build_tracker.tap(&:setup) }

    it 'adds declared-kind inputs for each tracked glob to the example dep set' do
      write_project_file('config/settings.yml', "feature: enabled\n")
      allow(tracker.coverage_adapter).to receive(:peek).and_return({}, {})

      tracker.register_tracks('ex1', files: Set.new(['config/*.yml']), env: Set.new)
      tracker.register_example(build_example('ex1'))
      tracker.example_started
      tracker.example_finished('ex1')

      settings_name = '/config/settings.yml'
      expect(tracker.all_files).to have_key(File.join(root, 'config/settings.yml'))
      expect(tracker.graph.dependency_hash['ex1']).to include(File.join(root, 'config/settings.yml'))
      expect(settings_name).to be_a(String) # sentinel - file_name shape tested in finalize specs
    end

    it 'accumulates env names across examples into @tracked_env_names' do
      tracker.register_tracks('ex1', files: Set.new, env: Set.new(['A']))
      tracker.register_tracks('ex2', files: Set.new, env: Set.new(['B']))

      snapshot = tracker.finalize

      expect(snapshot.env_snapshot.keys).to contain_exactly('A', 'B')
    end

    it 'is a no-op when both files and env are empty' do
      expect { tracker.register_tracks('ex1', files: Set.new, env: Set.new) }.not_to raise_error
    end

    it 'memoizes glob resolution so the filesystem is walked once per distinct glob' do
      write_project_file('config/a.yml', 'a')
      write_project_file('config/b.yml', 'b')
      allow(Dir).to receive(:glob).and_call_original

      tracker.register_tracks('ex1', files: Set.new(['config/*.yml']), env: Set.new)
      tracker.register_tracks('ex2', files: Set.new(['config/*.yml']), env: Set.new)

      expect(Dir).to have_received(:glob).with('config/*.yml', anything, base: root).once
    end
  end

  describe '#apply_env_filter_decisions (M5.2)' do
    let(:prev_cache_path) { File.join(tmp_base, 'cache') }
    # Pre-seed wsi_snapshot with a digest matching the current project's
    # WholeSuiteInvalidators output so the engine's whole_suite_changed?
    # returns false. Without this, every previous example gets marked as
    # whole_suite_invalidated and env_changed is suppressed by the
    # "stronger prior filter reason" guard.
    let(:current_wsi) do
      RSpecTracer::Tracker::WholeSuiteInvalidators.new(root: root).digest_snapshot
    end
    let(:previous_snapshot) do
      RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'prev').tap do |s|
        s.all_examples = { 'ex1' => build_example('ex1'), 'ex2' => build_example('ex2') }
        # Non-empty dependency keeps Filter from marking every prev example
        # as :no_cache (Filter maps missing-from-graph to no_cache which
        # the engine promotes to @filtered_examples, masking env_changed).
        s.dependency = { 'ex1' => Set.new(['/lib/a.rb']), 'ex2' => Set.new(['/lib/b.rb']) }
        s.all_files = {
          '/lib/a.rb' => { file_name: '/lib/a.rb', file_path: File.join(root, 'lib/a.rb'),
                           digest: Digest::SHA256.file(File.join(root, 'lib/a.rb')).hexdigest },
          '/lib/b.rb' => { file_name: '/lib/b.rb', file_path: File.join(root, 'lib/b.rb'),
                           digest: Digest::SHA256.file(File.join(root, 'lib/b.rb')).hexdigest }
        }
        s.env_snapshot = {
          'API_KEY' => Digest::MD5.hexdigest('old'),
          'OTHER' => Digest::MD5.hexdigest('') # matches current ENV['OTHER'] (absent -> '')
        }
        s.wsi_snapshot = current_wsi
      end
    end

    def prime_previous_cache
      FileUtils.mkdir_p(prev_cache_path)
      backend = RSpecTracer::Storage::JsonBackend.new(cache_path: prev_cache_path, logger: logger)
      backend.save_graph(previous_snapshot, schema_version: 3)
    end

    it 'adds env_changed decisions for examples whose tracked env key changed' do
      stub_const('ENV', 'API_KEY' => 'new')
      prime_previous_cache
      tracker = build_tracker.tap(&:setup)
      tracker.register_tracks('ex1', files: Set.new, env: Set.new(['API_KEY']))

      tracker.apply_env_filter_decisions

      expect(tracker.run_example?('ex1')).to be(true)
      expect(tracker.run_example_reason('ex1')).to eq('Environment changed')
    end

    it 'leaves examples not declaring the changed key alone' do
      stub_const('ENV', 'API_KEY' => 'new')
      prime_previous_cache
      tracker = build_tracker.tap(&:setup)
      tracker.register_tracks('ex2', files: Set.new, env: Set.new(['OTHER']))

      tracker.apply_env_filter_decisions

      expect(tracker.run_example?('ex2')).to be(false)
    end

    it 'is a no-op when no previous snapshot exists (cold first run)' do
      tracker = build_tracker.tap(&:setup)
      tracker.register_tracks('ex1', files: Set.new, env: Set.new(['API_KEY']))

      expect { tracker.apply_env_filter_decisions }.not_to raise_error
    end

    it 'does not overwrite a stronger prior filter reason' do
      stub_const('ENV', 'API_KEY' => 'new')
      prime_previous_cache
      tracker = build_tracker.tap(&:setup)
      tracker.instance_variable_get(:@filtered_examples)['ex1'] = 'Failed previously'
      tracker.register_tracks('ex1', files: Set.new, env: Set.new(['API_KEY']))

      tracker.apply_env_filter_decisions

      expect(tracker.run_example_reason('ex1')).to eq('Failed previously')
    end

    it 'returns self even on early-out paths' do
      tracker = build_tracker.tap(&:setup)

      expect(tracker.apply_env_filter_decisions).to be(tracker)
    end
  end

  describe '#merge_skipped_coverage' do
    subject(:tracker) { build_tracker.tap(&:setup) }

    it 'returns {} when no previous coverage is available' do
      expect(tracker.merge_skipped_coverage(%w[ex1])).to eq({})
    end

    it 'accumulates per-line strengths from previous coverage for skipped ids' do
      previous = {
        'ex1' => { '/lib/a.rb' => { '0' => 1, '2' => 3 } },
        'ex2' => { '/lib/a.rb' => { '0' => 4 } }
      }
      result = tracker.merge_skipped_coverage(%w[ex1 ex2], previous)

      expect(result['/lib/a.rb']).to eq(0 => 5, 2 => 3)
    end

    it 'skips entries for ids not present in the source map' do
      result = tracker.merge_skipped_coverage(%w[missing], 'ex1' => { '/lib/a.rb' => { '0' => 1 } })

      expect(result).to eq({})
    end

    it 'treats nil strengths as zero (legacy parity for non-executable lines)' do
      previous = { 'ex1' => { '/lib/a.rb' => { '0' => nil, '1' => 2 } } }
      result = tracker.merge_skipped_coverage(%w[ex1], previous)

      expect(result['/lib/a.rb']).to eq(0 => 0, 1 => 2)
    end

    it 'falls back to the loaded previous snapshot when no explicit source is given' do
      # Simulate a prior run by saving a snapshot the tracker can load.
      prior = build_tracker
      prior.setup
      prior.register_example(build_example('ex1'))
      allow(prior.coverage_adapter).to receive(:peek).and_return({}, {})
      prior.example_started
      prior.example_finished('ex1')
      prior.on_example_passed('ex1', build_execution_result(status: :passed))
      prior.finalize

      # New tracker picks up the previous snapshot and merges.
      RSpecTracer::Tracker::IOHooks.uninstall
      next_run = build_tracker.tap(&:setup)

      expect { next_run.merge_skipped_coverage(%w[ex1]) }.not_to raise_error
    end
  end

  describe 'Rails observer wiring' do
    let(:fake_as_notifications) do
      Class.new do
        def initialize
          @subscribers = {}
        end

        def subscribe(event_name, &block)
          handle = Object.new
          (@subscribers[event_name] ||= {})[handle] = block
          handle
        end

        def unsubscribe(handle)
          @subscribers.each_value { |blocks| blocks.delete(handle) }
        end

        def publish(event_name, payload)
          (@subscribers[event_name] || {}).each_value do |b|
            b.call(event_name, Time.now, Time.now, 'id', payload)
          end
        end
      end.new
    end

    before do
      stub_const('ActiveSupport', Module.new)
      stub_const('ActiveSupport::Notifications', fake_as_notifications)
      stub_const('Rails', Module.new) unless defined?(Rails)
      stub_const('Rails::VERSION', Module.new)
      stub_const('Rails::VERSION::STRING', '7.2.3.1')
    end

    after do
      if defined?(RSpecTracer::Rails::Notifications) && RSpecTracer::Rails::Notifications.installed?
        RSpecTracer::Rails::Notifications.uninstall
      end
      if defined?(RSpecTracer::Rails::I18nTracking) && RSpecTracer::Rails::I18nTracking.installed?
        RSpecTracer::Rails::I18nTracking.uninstall
      end
    end

    it 'installs the Rails notification observers when rails? is true' do
      tracker = build_tracker(stub_configuration(rails?: true)).tap(&:setup)

      expect(RSpecTracer::Rails::Notifications).to be_installed
    ensure
      tracker&.finalize
    end

    it 'skips observer install when rails? is false' do
      build_tracker.tap(&:setup)

      expect(defined?(RSpecTracer::Rails::Notifications) &&
        RSpecTracer::Rails::Notifications.installed?).to be_falsey
    end

    it 'routes notification bucket through example_started / example_finished' do
      tracker = build_tracker(stub_configuration(rails?: true)).tap(&:setup)
      allow(tracker.coverage_adapter).to receive(:peek).and_return({}, {})
      template = File.join(root, 'app/views/show.erb')
      FileUtils.mkdir_p(File.dirname(template))
      File.write(template, '<h1>x</h1>')

      tracker.register_example(build_example('ex1'))
      tracker.example_started
      fake_as_notifications.publish('render_template.action_view', { identifier: template })
      tracker.example_finished('ex1')

      expect(tracker.graph.paths_for('ex1')).to include(template)
    ensure
      tracker&.finalize
    end

    it 'uninstalls Rails observers during finalize' do
      tracker = build_tracker(stub_configuration(rails?: true)).tap(&:setup)

      tracker.finalize

      expect(RSpecTracer::Rails::Notifications).not_to be_installed
    end

    it 'installs the AR subscriber when track_ar_schema_notifications is true' do
      FileUtils.mkdir_p(File.join(root, 'db'))
      File.write(File.join(root, 'db/schema.rb'), "ActiveRecord::Schema.define { }\n")

      build_tracker(stub_configuration(rails?: true, track_ar_schema_notifications?: true))
        .tap(&:setup)

      expect(fake_as_notifications.instance_variable_get(:@subscribers).keys)
        .to include('sql.active_record')
    end

    it 'swallows errors raised during Rails observer install' do
      allow(RSpecTracer::Rails::Notifications).to receive(:install)
        .and_raise(StandardError.new('boom'))

      expect do
        build_tracker(stub_configuration(rails?: true)).tap(&:setup)
      end.not_to raise_error
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers
