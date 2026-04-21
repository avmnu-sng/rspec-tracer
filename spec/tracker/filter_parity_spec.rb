# frozen_string_literal: true

# Behavior-parity test: the new M3.5 Filter must select the same
# example set the 1.x runner.rb filter would, for a given synthetic
# snapshot. Invokes the legacy private filter methods directly
# (via `Runner.allocate` + instance_variable_set to bypass the
# initialize-time cache load) to avoid any disk or RSpec integration
# dependency.
#
# Reason fidelity is not asserted - 1.x's reason symbols match the
# new Filter's only coincidentally; the gate is the Set of ids.
# rubocop:disable RSpec/ExampleLength, RSpec/DescribeClass, Metrics/ParameterLists
require 'set'
require 'rspec_tracer/cache'
require 'rspec_tracer/runner'
require 'rspec_tracer/tracker/dependency_graph'
require 'rspec_tracer/tracker/example_registry'
require 'rspec_tracer/tracker/filter'

RSpec.describe 'Filter parity with legacy runner.rb' do
  def build_cache(all_examples:, interrupted:, flaky:, failed:, pending:, dependency:)
    cache = RSpecTracer::Cache.new
    cache.instance_variable_set(:@all_examples, all_examples)
    cache.instance_variable_set(:@interrupted_examples, Set.new(interrupted))
    cache.instance_variable_set(:@flaky_examples, Set.new(flaky))
    cache.instance_variable_set(:@failed_examples, Set.new(failed))
    cache.instance_variable_set(:@pending_examples, Set.new(pending))
    cache.instance_variable_set(:@dependency, dependency.transform_values { |v| Set.new(v) })
    cache
  end

  def legacy_run_set(cache:, changed_files:, all_example_ids:)
    reporter = instance_double(RSpecTracer::Reporter, register_possibly_flaky_example: nil)
    runner = RSpecTracer::Runner.allocate
    runner.instance_variable_set(:@cache, cache)
    runner.instance_variable_set(:@reporter, reporter)
    runner.instance_variable_set(:@changed_files, Set.new(changed_files))
    runner.instance_variable_set(:@filtered_examples, {})
    runner.instance_variable_set(:@possibly_flaky_examples, {})
    runner.send(:filter_by_example_status)
    runner.send(:filter_by_files_changed)
    filtered = runner.instance_variable_get(:@filtered_examples)
    all_example_ids.each { |id| filtered[id] ||= :no_cache unless cache.all_examples.key?(id) }
    filtered.keys.to_set
  end

  def new_filter_run_set(graph:, registry:, change_set:, all_example_ids:, whole_suite_invalidated: false)
    result = RSpecTracer::Tracker::Filter.select(
      graph: graph, change_set: change_set, registry: registry,
      whole_suite_invalidated: whole_suite_invalidated, all_example_ids: all_example_ids
    )
    result.keys.to_set
  end

  def new_filter_from_cache(cache:, change_set:, all_example_ids:)
    graph = RSpecTracer::Tracker::DependencyGraph.new
    cache.dependency.each { |id, paths| graph.register_example(id, paths) }
    registry = RSpecTracer::Tracker::ExampleRegistry.new
    cache.all_examples.each_key { |id| registry.register(id) }
    cache.interrupted_examples.each { |id| registry.update_status(id, :interrupted) }
    cache.flaky_examples.each { |id| registry.update_status(id, :flaky) }
    cache.failed_examples.each { |id| registry.update_status(id, :failed) }
    cache.pending_examples.each { |id| registry.update_status(id, :pending) }
    new_filter_run_set(
      graph: graph, registry: registry, change_set: change_set, all_example_ids: all_example_ids
    )
  end

  shared_examples 'parity' do |label|
    it "matches legacy for scenario: #{label}" do
      legacy = legacy_run_set(
        cache: cache, changed_files: change_set, all_example_ids: all_example_ids
      )
      new_impl = new_filter_from_cache(
        cache: cache, change_set: change_set, all_example_ids: all_example_ids
      )

      expect(new_impl).to eq(legacy)
    end
  end

  context 'when nothing changed and no always-re-run statuses' do
    let(:cache) do
      build_cache(
        all_examples: { 'ex1' => {}, 'ex2' => {} },
        interrupted: [], flaky: [], failed: [], pending: [],
        dependency: { 'ex1' => ['/a.rb'], 'ex2' => ['/b.rb'] }
      )
    end
    let(:change_set) { Set.new }
    let(:all_example_ids) { Set['ex1', 'ex2'] }

    it_behaves_like 'parity', 'quiet run'
  end

  context 'when a file changed and one example depends on it' do
    let(:cache) do
      build_cache(
        all_examples: { 'ex1' => {}, 'ex2' => {} },
        interrupted: [], flaky: [], failed: [], pending: [],
        dependency: { 'ex1' => ['/a.rb'], 'ex2' => ['/b.rb'] }
      )
    end
    let(:change_set) { Set['/a.rb'] }
    let(:all_example_ids) { Set['ex1', 'ex2'] }

    it_behaves_like 'parity', 'single file changed'
  end

  context 'when always-re-run statuses populate the set' do
    let(:cache) do
      build_cache(
        all_examples: { 'ex1' => {}, 'ex2' => {}, 'ex3' => {}, 'ex4' => {} },
        interrupted: ['ex1'], flaky: ['ex2'], failed: ['ex3'], pending: ['ex4'],
        dependency: { 'ex1' => [], 'ex2' => [], 'ex3' => [], 'ex4' => [] }
      )
    end
    let(:change_set) { Set.new }
    let(:all_example_ids) { Set['ex1', 'ex2', 'ex3', 'ex4'] }

    it_behaves_like 'parity', 'all four always-re-run statuses'
  end

  context 'when always-re-run overlaps with files_changed' do
    let(:cache) do
      build_cache(
        all_examples: { 'ex1' => {}, 'ex2' => {} },
        interrupted: [], flaky: [], failed: ['ex1'], pending: [],
        dependency: { 'ex1' => ['/a.rb'], 'ex2' => ['/a.rb'] }
      )
    end
    let(:change_set) { Set['/a.rb'] }
    let(:all_example_ids) { Set['ex1', 'ex2'] }

    it_behaves_like 'parity', 'failed + file changed'
  end

  context 'when new examples appear that are not in the cache' do
    let(:cache) do
      build_cache(
        all_examples: { 'ex1' => {} },
        interrupted: [], flaky: [], failed: [], pending: [],
        dependency: { 'ex1' => ['/a.rb'] }
      )
    end
    let(:change_set) { Set.new }
    let(:all_example_ids) { Set['ex1', 'ex2', 'ex3'] }

    it_behaves_like 'parity', 'new examples not in cache'
  end

  context 'when nothing is in the cache (first run)' do
    let(:cache) do
      build_cache(
        all_examples: {}, interrupted: [], flaky: [], failed: [], pending: [],
        dependency: {}
      )
    end
    let(:change_set) { Set.new }
    let(:all_example_ids) { Set['ex1', 'ex2', 'ex3'] }

    it_behaves_like 'parity', 'first run (empty cache)'
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/DescribeClass, Metrics/ParameterLists
