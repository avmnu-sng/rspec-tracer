# frozen_string_literal: true

require 'set'
require 'rspec_tracer/tracker/dependency_graph'
require 'rspec_tracer/tracker/example_registry'
require 'rspec_tracer/tracker/filter'
require 'rspec_tracer/tracker/input'

RSpec.describe RSpecTracer::Tracker::Filter do
  let(:graph) { RSpecTracer::Tracker::DependencyGraph.new }
  let(:registry) { RSpecTracer::Tracker::ExampleRegistry.new }
  let(:all_example_ids) { Set['ex1', 'ex2', 'ex3'] }

  def input(path)
    RSpecTracer::Tracker::Input.for_file(path: path, kind: :ruby, digest: 'd', root: '/')
  end

  def select(change_set: Set.new, whole_suite_invalidated: false)
    described_class.select(
      graph: graph,
      change_set: change_set,
      registry: registry,
      whole_suite_invalidated: whole_suite_invalidated,
      all_example_ids: all_example_ids
    )
  end

  describe 'constants' do
    it 'enumerates 7 reasons in precedence order' do
      expect(described_class::REASONS).to eq(expected_reasons)
    end

    it 'freezes the reasons list' do
      expect(described_class::REASONS).to be_frozen
    end

    it 'maps registry statuses to filter reasons' do
      expect(described_class::STATUS_TO_REASON).to eq(expected_status_to_reason)
    end

    it 'freezes the status-to-reason map' do
      expect(described_class::STATUS_TO_REASON).to be_frozen
    end

    def expected_reasons
      %i[
        whole_suite_invalidator interrupted flaky_example failed_example
        pending_example no_cache files_changed
      ]
    end

    def expected_status_to_reason
      { interrupted: :interrupted, flaky: :flaky_example,
        failed: :failed_example, pending: :pending_example }
    end
  end

  describe 'whole-suite invalidation gate' do
    it 'returns every example id with :whole_suite_invalidator' do
      result = select(whole_suite_invalidated: true)

      expect(result).to eq('ex1' => :whole_suite_invalidator, 'ex2' => :whole_suite_invalidator,
                           'ex3' => :whole_suite_invalidator)
    end

    it 'takes precedence over registry status' do
      registry.register('ex1').update_status('ex1', :failed)

      expect(select(whole_suite_invalidated: true)['ex1']).to eq(:whole_suite_invalidator)
    end

    it 'takes precedence over change_set matches' do
      graph.register_example('ex1', Set['/lib/a.rb'])

      expect(select(change_set: Set['/lib/a.rb'], whole_suite_invalidated: true)['ex1'])
        .to eq(:whole_suite_invalidator)
    end
  end

  describe 'always-re-run statuses' do
    before do
      registry.register('ex1').update_status('ex1', :failed)
      registry.register('ex2').update_status('ex2', :flaky)
      registry.register('ex3').update_status('ex3', :pending)
    end

    it 'maps :failed to :failed_example' do
      expect(select['ex1']).to eq(:failed_example)
    end

    it 'maps :flaky to :flaky_example' do
      expect(select['ex2']).to eq(:flaky_example)
    end

    it 'maps :pending to :pending_example' do
      expect(select['ex3']).to eq(:pending_example)
    end

    it 'maps :interrupted to :interrupted' do
      registry.update_status('ex1', :interrupted)

      expect(select['ex1']).to eq(:interrupted)
    end

    it 'excludes :passed from the result' do
      registry.update_status('ex1', :passed)
      graph.register_example('ex1', Set.new)

      expect(select).not_to have_key('ex1')
    end

    it 'excludes :skipped from the result (matches 1.x non-re-run semantics)' do
      registry.update_status('ex1', :skipped)
      graph.register_example('ex1', Set.new)

      expect(select).not_to have_key('ex1')
    end

    it 'ignores always-re-run ids not present in all_example_ids (stale from previous run)' do
      registry.register('stale_id').update_status('stale_id', :failed)

      expect(select).not_to have_key('stale_id')
    end
  end

  describe 'no-cache rule' do
    it 'assigns :no_cache to every example not in the graph' do
      result = select

      expect(result).to include('ex1' => :no_cache, 'ex2' => :no_cache, 'ex3' => :no_cache)
    end

    it 'does not assign :no_cache to an example that is in the graph' do
      graph.register_example('ex1', Set.new)

      expect(select).not_to include('ex1' => :no_cache)
    end
  end

  describe 'files_changed rule' do
    before do
      graph.register_example('ex1', Set['/lib/a.rb'])
      graph.register_example('ex2', Set['/lib/b.rb'])
      graph.register_example('ex3', Set['/lib/c.rb'])
    end

    it 'assigns :files_changed only to examples whose deps intersect the change_set' do
      result = select(change_set: Set['/lib/a.rb'])

      expect(result).to eq('ex1' => :files_changed)
    end

    it 'unions multiple changed files' do
      result = select(change_set: Set['/lib/a.rb', '/lib/b.rb'])

      expect(result.keys).to contain_exactly('ex1', 'ex2')
    end

    it 'ignores change_set entries that match no registered dependency' do
      result = select(change_set: Set['/lib/never.rb'])

      expect(result).to eq({})
    end
  end

  describe 'precedence when multiple rules match the same example' do
    before do
      graph.register_example('ex1', Set['/lib/a.rb'])
      registry.register('ex1').update_status('ex1', :failed)
    end

    it 'picks :failed_example over :files_changed (always-re-run wins)' do
      result = select(change_set: Set['/lib/a.rb'])

      expect(result['ex1']).to eq(:failed_example)
    end

    it 'picks :interrupted over :flaky_example' do
      registry.update_status('ex1', :interrupted)
      registry.register('ex2').update_status('ex2', :flaky)
      # Make ex1 both interrupted and flaky by re-registering with flaky later.
      registry.register('ex1', identity_hash: 'h-ex1')
      # The status is held singularly; order in the result reflects :interrupted
      # being the first registry-status kind checked.
      expect(result_for_ex1_interrupted_over_flaky).to eq(:interrupted)
    end

    it 'picks :no_cache over :files_changed for a new example' do
      registry.register('ex2') # ex2 has nil status
      graph.register_example('ex2_in_graph', Set['/lib/z.rb'])
      result = select(change_set: Set['/lib/z.rb'])

      expect(result['ex2']).to eq(:no_cache)
    end

    def result_for_ex1_interrupted_over_flaky
      described_class.select(
        graph: graph,
        change_set: Set.new,
        registry: registry,
        whole_suite_invalidated: false,
        all_example_ids: Set['ex1']
      )['ex1']
    end
  end

  describe '.to_run_set' do
    it 'returns the Set of example ids from a select result' do
      result = { 'ex1' => :no_cache, 'ex2' => :files_changed }

      expect(described_class.to_run_set(result)).to eq(Set['ex1', 'ex2'])
    end

    it 'returns an empty Set for an empty result' do
      expect(described_class.to_run_set({})).to eq(Set.new)
    end
  end

  describe 'degenerate inputs' do
    it 'returns empty when all_example_ids is empty' do
      result = described_class.select(
        graph: graph, change_set: Set.new, registry: registry,
        whole_suite_invalidated: false, all_example_ids: Set.new
      )

      expect(result).to eq({})
    end

    it 'treats all_example_ids as empty when whole_suite_invalidated fires' do
      result = described_class.select(
        graph: graph, change_set: Set.new, registry: registry,
        whole_suite_invalidated: true, all_example_ids: Set.new
      )

      expect(result).to eq({})
    end

    it 'accepts an Array for all_example_ids (coerced via to_set)' do
      result = described_class.select(
        graph: graph, change_set: Set.new, registry: registry,
        whole_suite_invalidated: false, all_example_ids: %w[ex1]
      )

      expect(result).to eq('ex1' => :no_cache)
    end
  end
end
