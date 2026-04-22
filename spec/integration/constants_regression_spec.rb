# frozen_string_literal: true

# Regression spec for KNOWN_ISSUES B10: the constants-lookup blind spot
# in the diff-based coverage model.
#
# Scenario
# --------
# Two examples:
#   - ex_trigger: loads user_of_constant.rb which requires constants.rb
#     (Coverage sees both files execute during this example).
#   - ex_reader:  references USER_OF_CONSTANT::VALUE but the require
#     has already run - Coverage does NOT record a diff for constants.rb
#     during this example's execution window, because no new line in
#     constants.rb fires (the file was already loaded).
#
# Without the loaded-files tracker, ex_reader's recorded dependency set
# is just {user_of_constant.rb}. If constants.rb changes, ex_reader is
# incorrectly skipped - the blind spot.
#
# With the tracker, ex_reader's dep set is the transitive closure of
# files loaded up to its execution point, which includes constants.rb.
# Changing constants.rb flips ex_reader into the Filter's re-run set.
#
# Drives the pipeline in-process (LoadedFilesTracker + DependencyGraph +
# ExampleRegistry + Filter) with a stubbed peek. The full end-to-end
# test (subprocess + Open3 against a real fixture) waits for M3.6,
# where Tracker.setup exists to orchestrate the observers.
require 'fileutils'
require 'set'
require 'tmpdir'
require 'rspec_tracer/tracker/dependency_graph'
require 'rspec_tracer/tracker/example_registry'
require 'rspec_tracer/tracker/filter'
require 'rspec_tracer/tracker/loaded_files_tracker'

# Composition scenarios operate on whole pipelines; splitting to
# satisfy metric cops scatters the narrative.
# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength
RSpec.describe 'constants regression (KNOWN_ISSUES B10)' do
  let(:tmp_base) { Dir.mktmpdir }
  let(:root) { File.join(tmp_base, 'project').tap { |p| FileUtils.mkdir_p(p) } }

  let(:constants_path)  { File.join(root, 'lib/constants.rb') }
  let(:user_path)       { File.join(root, 'lib/user_of_constant.rb') }

  before do
    FileUtils.mkdir_p(File.dirname(constants_path))
    File.write(constants_path, "module Constants\n  VALUE = 1\nend\n")
    File.write(user_path, "require_relative 'constants'\nUSER = Constants::VALUE\n")
  end

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  def build_tracker(enabled: true)
    # Peek script: the trigger example loads both files; the reader
    # example sees the same two keys (already loaded, no new diffs).
    # Coverage.peek_result.keys is monotonic across a process, so
    # after ex_trigger, both files stay in peek output forever.
    peek_script = [
      [],                                # capture_boot_set! (nothing loaded yet)
      [user_path, constants_path],       # after ex_trigger stop
      [user_path, constants_path]        # after ex_reader stop
    ]
    RSpecTracer::Tracker::LoadedFilesTracker.new(
      root: root, peek: -> { peek_script.shift || [] }, enabled: enabled
    )
  end

  # Simulates what M3.6 will wire: at start_example time, the caller
  # snapshots loaded_set_inputs; at stop_example time, stop_example's
  # return value is the delta; union is the example's Input set.
  def simulate_run(tracker)
    tracker.capture_boot_set!
    graph = RSpecTracer::Tracker::DependencyGraph.new
    registry = RSpecTracer::Tracker::ExampleRegistry.new
    registry.register('ex_trigger').update_status('ex_trigger', :passed)
    registry.register('ex_reader').update_status('ex_reader', :passed)

    # ex_trigger: coverage-diff observed user_path executing, and as a
    # side effect pulled constants_path into the process.
    trigger_baseline = tracker.loaded_set_inputs
    trigger_new = tracker.stop_example('ex_trigger')
    graph.register_example('ex_trigger', trigger_baseline | trigger_new)

    # ex_reader: coverage diff produces NOTHING for constants_path
    # (already loaded - no new line execution in constants.rb during
    # this window). loaded_set_inputs carries it in as a transitive
    # dep.
    reader_baseline = tracker.loaded_set_inputs
    reader_new = tracker.stop_example('ex_reader')
    graph.register_example('ex_reader', reader_baseline | reader_new)

    [graph, registry]
  end

  def filter_result(graph, registry, change_set:)
    RSpecTracer::Tracker::Filter.select(
      graph: graph, change_set: change_set, registry: registry,
      whole_suite_invalidated: false,
      all_example_ids: Set['ex_trigger', 'ex_reader']
    )
  end

  describe 'with loaded-files tracker enabled' do
    it 'attributes constants.rb to ex_reader even though its coverage diff is empty' do
      tracker = build_tracker(enabled: true)
      graph, = simulate_run(tracker)

      expect(graph.paths_for('ex_reader')).to include(constants_path)
    end

    it 'attributes user_of_constant.rb to ex_reader transitively' do
      tracker = build_tracker(enabled: true)
      graph, = simulate_run(tracker)

      expect(graph.paths_for('ex_reader')).to include(user_path)
    end

    it 'Filter re-runs ex_reader when constants.rb changes' do
      tracker = build_tracker(enabled: true)
      graph, registry = simulate_run(tracker)
      result = filter_result(graph, registry, change_set: Set[constants_path])

      expect(result['ex_reader']).to eq(:files_changed)
    end

    it 'Filter re-runs ex_trigger when constants.rb changes (same attribution)' do
      tracker = build_tracker(enabled: true)
      graph, registry = simulate_run(tracker)
      result = filter_result(graph, registry, change_set: Set[constants_path])

      expect(result['ex_trigger']).to eq(:files_changed)
    end
  end

  describe 'with loaded-files tracker disabled (1.x behavior restored)' do
    it 'does NOT attribute constants.rb to ex_reader' do
      tracker = build_tracker(enabled: false)
      graph, = simulate_run(tracker)

      expect(graph.paths_for('ex_reader')).not_to include(constants_path)
    end

    it 'Filter skips ex_reader when only constants.rb changes (the B10 blind spot)' do
      tracker = build_tracker(enabled: false)
      graph, registry = simulate_run(tracker)
      result = filter_result(graph, registry, change_set: Set[constants_path])

      expect(result).not_to have_key('ex_reader')
    end
  end

  describe 'boot-set whole-suite invalidation' do
    it 'flags boot_set_invalidated? when a boot-set file changes' do
      # Boot set: simulate spec_helper.rb loaded before any example.
      helper_path = File.join(root, 'spec/spec_helper.rb')
      FileUtils.mkdir_p(File.dirname(helper_path))
      File.write(helper_path, "require 'rspec'\n")
      peek_script = [[helper_path]]
      tracker = RSpecTracer::Tracker::LoadedFilesTracker.new(
        root: root, peek: -> { peek_script.shift || [] }
      )
      tracker.capture_boot_set!
      previous = tracker.boot_set_digest_snapshot.dup

      # Simulate spec_helper.rb edit on next run.
      File.write(helper_path, "require 'rspec'\nrequire 'simplecov'\n")
      next_tracker = RSpecTracer::Tracker::LoadedFilesTracker.new(
        root: root, peek: -> { [helper_path] }
      )
      next_tracker.capture_boot_set!

      expect(next_tracker.boot_set_invalidated?(previous)).to be(true)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength
