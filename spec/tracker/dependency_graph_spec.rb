# frozen_string_literal: true

require 'set'
require 'rspec_tracer/tracker/dependency_graph'
require 'rspec_tracer/tracker/input'

RSpec.describe RSpecTracer::Tracker::DependencyGraph do
  subject(:graph) { described_class.new }

  def input(path, kind: :ruby)
    RSpecTracer::Tracker::Input.for_file(
      path: path, kind: kind, digest: 'd', root: '/'
    )
  end

  describe '#initialize' do
    it 'starts empty' do
      expect(graph.empty?).to be(true)
    end

    it 'exposes no example ids' do
      expect(graph.example_ids).to eq([])
    end
  end

  describe '#register_example' do
    it 'stores the forward entry as a Set of paths' do
      graph.register_example('ex1', Set[input('/lib/a.rb'), input('/lib/b.rb')])

      expect(graph.paths_for('ex1')).to eq(Set['/lib/a.rb', '/lib/b.rb'])
    end

    it 'accepts raw path strings (for Snapshot-load callers)' do
      graph.register_example('ex1', Set['/lib/a.rb'])

      expect(graph.paths_for('ex1')).to eq(Set['/lib/a.rb'])
    end

    it 'accepts a mixed collection of Inputs and strings' do
      graph.register_example('ex1', Set[input('/lib/a.rb'), '/lib/b.rb'])

      expect(graph.paths_for('ex1')).to eq(Set['/lib/a.rb', '/lib/b.rb'])
    end

    it 'replaces the forward entry when the same example is re-registered' do
      graph.register_example('ex1', Set[input('/lib/a.rb')])
      graph.register_example('ex1', Set[input('/lib/b.rb')])

      expect(graph.paths_for('ex1')).to eq(Set['/lib/b.rb'])
    end

    it 'returns self for chaining' do
      expect(graph.register_example('ex1', Set.new)).to be(graph)
    end

    it 'tolerates nil inputs by storing the empty set' do
      graph.register_example('ex1', nil)

      expect(graph.paths_for('ex1')).to eq(Set.new)
    end

    it 'invalidates the inverse index' do
      graph.register_example('ex1', Set[input('/lib/a.rb')])
      graph.examples_depending_on(Set['/lib/a.rb']) # warm inverse
      graph.register_example('ex2', Set[input('/lib/a.rb')])

      expect(graph.examples_depending_on(Set['/lib/a.rb'])).to eq(Set['ex1', 'ex2'])
    end
  end

  describe '#paths_for' do
    it 'returns an empty set for unknown example ids' do
      expect(graph.paths_for('nope')).to eq(Set.new)
    end
  end

  describe '#example_ids' do
    it 'returns every registered id' do
      graph.register_example('ex1', Set.new)
      graph.register_example('ex2', Set.new)

      expect(graph.example_ids).to contain_exactly('ex1', 'ex2')
    end
  end

  describe '#empty?' do
    it 'is true initially' do
      expect(graph.empty?).to be(true)
    end

    it 'becomes false after a register_example call' do
      graph.register_example('ex1', Set.new)

      expect(graph.empty?).to be(false)
    end
  end

  describe '#examples_depending_on' do
    it 'returns an empty set when the graph is empty' do
      expect(graph.examples_depending_on(Set['/lib/a.rb'])).to eq(Set.new)
    end

    it 'returns an empty set when the change set is empty' do
      graph.register_example('ex1', Set[input('/lib/a.rb')])

      expect(graph.examples_depending_on(Set.new)).to eq(Set.new)
    end

    it 'finds single-example dependencies' do
      graph.register_example('ex1', Set[input('/lib/a.rb')])

      expect(graph.examples_depending_on(Set[input('/lib/a.rb')])).to eq(Set['ex1'])
    end

    it 'unions examples across multiple changed files' do
      graph.register_example('ex1', Set[input('/lib/a.rb')])
      graph.register_example('ex2', Set[input('/lib/b.rb')])

      expect(graph.examples_depending_on(Set['/lib/a.rb', '/lib/b.rb']))
        .to eq(Set['ex1', 'ex2'])
    end

    it 'dedupes examples that depend on multiple changed files' do
      graph.register_example('ex1', Set[input('/lib/a.rb'), input('/lib/b.rb')])

      expect(graph.examples_depending_on(Set['/lib/a.rb', '/lib/b.rb']))
        .to eq(Set['ex1'])
    end

    it 'returns empty set when no example depends on the changed files' do
      graph.register_example('ex1', Set[input('/lib/a.rb')])

      expect(graph.examples_depending_on(Set['/lib/unrelated.rb'])).to eq(Set.new)
    end

    it 'treats Input and raw path equivalently on the path dimension' do
      graph.register_example('ex1', Set[input('/lib/a.rb', kind: :ruby)])
      graph.register_example('ex2', Set[input('/lib/a.rb', kind: :declared)])

      expect(graph.examples_depending_on(Set['/lib/a.rb'])).to eq(Set['ex1', 'ex2'])
    end
  end

  describe '#dependency_hash' do
    it 'mirrors the forward map by path' do
      graph.register_example('ex1', Set[input('/lib/a.rb'), input('/lib/b.rb')])

      expect(graph.dependency_hash).to eq('ex1' => Set['/lib/a.rb', '/lib/b.rb'])
    end

    it 'returns fresh Sets (mutation does not leak into the graph)' do
      graph.register_example('ex1', Set[input('/lib/a.rb')])
      graph.dependency_hash['ex1'].clear

      expect(graph.paths_for('ex1')).to eq(Set['/lib/a.rb'])
    end
  end

  describe '#reverse_dependency_hash' do
    it 'maps each path to the set of examples that depend on it' do
      graph.register_example('ex1', Set[input('/lib/a.rb')])
      graph.register_example('ex2', Set[input('/lib/a.rb'), input('/lib/b.rb')])

      expect(graph.reverse_dependency_hash)
        .to eq('/lib/a.rb' => Set['ex1', 'ex2'], '/lib/b.rb' => Set['ex2'])
    end

    it 'returns fresh Sets (mutation does not leak into the graph)' do
      graph.register_example('ex1', Set[input('/lib/a.rb')])
      graph.reverse_dependency_hash['/lib/a.rb'].clear

      expect(graph.examples_depending_on(Set['/lib/a.rb'])).to eq(Set['ex1'])
    end

    it 'is empty when the graph has no examples' do
      expect(graph.reverse_dependency_hash).to eq({})
    end
  end
end
