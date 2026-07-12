# frozen_string_literal: true

# Property-based invariants for Tracker::Filter. Runs 500 iterations
# per property per the original acceptance criterion. Generators are
# pulled into a helper module because Rantly's property_of block
# evaluates in Rantly's instance context - closure-captured lets
# are not visible (same pattern as invalidation_monotonic_spec.rb
# and json_backend_corruption_spec.rb).
# rubocop:disable RSpec/ExampleLength, RSpec/DescribeClass, RSpec/MultipleExpectations
require 'set'
require 'rantly/rspec_extensions'

require 'rspec_tracer/tracker/dependency_graph'
require 'rspec_tracer/tracker/example_registry'
require 'rspec_tracer/tracker/filter'

PROPERTY_PATHS = %w[/lib/a.rb /lib/b.rb /lib/c.rb /lib/d.rb /lib/e.rb].freeze
PROPERTY_STATUSES = %i[passed failed pending interrupted flaky skipped].freeze
PROPERTY_EXAMPLE_COUNT = 12

module FilterPropertyGen
  module_function

  def scenario
    example_ids = (1..PROPERTY_EXAMPLE_COUNT).map { |i| "ex#{i}" }
    registered_ids = example_ids.sample(Rantly { range(0, PROPERTY_EXAMPLE_COUNT) })

    graph = RSpecTracer::Tracker::DependencyGraph.new
    registry = RSpecTracer::Tracker::ExampleRegistry.new
    registered_ids.each do |id|
      paths = PROPERTY_PATHS.sample(Rantly { range(0, PROPERTY_PATHS.size) })
      graph.register_example(id, paths.to_set)
      registry.register(id)
      registry.update_status(id, Rantly { choose(*PROPERTY_STATUSES) })
    end

    change_set = PROPERTY_PATHS.sample(Rantly { range(0, PROPERTY_PATHS.size) }).to_set
    {
      graph: graph,
      registry: registry,
      change_set: change_set,
      all_example_ids: example_ids.to_set,
      registered_ids: registered_ids.to_set
    }
  end
end

RSpec.describe 'Filter invariants' do
  def select(scenario, change_set: scenario[:change_set], whole_suite_invalidated: false)
    RSpecTracer::Tracker::Filter.select(
      graph: scenario[:graph],
      change_set: change_set,
      registry: scenario[:registry],
      whole_suite_invalidated: whole_suite_invalidated,
      all_example_ids: scenario[:all_example_ids]
    )
  end

  describe 'whole-suite gate dominates' do
    it 'returns every id with :whole_suite_invalidator when invalidated' do
      property_of { FilterPropertyGen.scenario }.check(500) do |scenario|
        result = select(scenario, whole_suite_invalidated: true)

        expect(result.keys.to_set).to eq(scenario[:all_example_ids])
        expect(result.values.uniq).to eq([:whole_suite_invalidator])
      end
    end
  end

  describe 'new examples always run with :no_cache' do
    it 'assigns :no_cache to every id not in the graph (unless an always-re-run status applies first)' do
      property_of { FilterPropertyGen.scenario }.check(500) do |scenario|
        result = select(scenario)
        new_ids = scenario[:all_example_ids] - scenario[:registered_ids]

        new_ids.each do |id|
          # New examples have no registry status (never registered via
          # ExampleRegistry#register in the generator). :no_cache is
          # always the reason.
          expect(result[id]).to eq(:no_cache)
        end
      end
    end
  end

  describe 'empty change set with no always-re-run statuses leaves registered examples alone' do
    it 'only selects new (no_cache) examples when nothing changed and no status triggers' do
      property_of { FilterPropertyGen.scenario }.check(500) do |scenario|
        # Clear every registered example to :passed so the always-re-run
        # set is empty; then verify only new examples appear in the
        # result.
        scenario[:registered_ids].each { |id| scenario[:registry].update_status(id, :passed) }
        result = select(scenario, change_set: Set.new)

        non_new_ids = result.keys.to_set & scenario[:registered_ids]
        expect(non_new_ids).to eq(Set.new)
      end
    end
  end

  describe 'change-set monotonicity' do
    it 'adding to change_set never shrinks the result' do
      property_of { FilterPropertyGen.scenario }.check(500) do |scenario|
        extra = PROPERTY_PATHS.sample(Rantly { range(0, PROPERTY_PATHS.size) })
        before = select(scenario, change_set: scenario[:change_set]).keys.to_set
        after = select(scenario, change_set: scenario[:change_set] | extra).keys.to_set

        expect(after).to be >= before
      end
    end
  end

  describe 'full-change invariant' do
    it 'a change_set covering every known path re-runs every example with deps' do
      property_of { FilterPropertyGen.scenario }.check(500) do |scenario|
        all_paths = PROPERTY_PATHS.to_set
        result = select(scenario, change_set: all_paths)
        examples_with_deps = scenario[:registered_ids].reject do |id|
          scenario[:graph].paths_for(id).empty?
        end

        examples_with_deps.each do |id|
          expect(result).to have_key(id), "ex=#{id} missing from full-change result"
        end
      end
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/DescribeClass, RSpec/MultipleExpectations
