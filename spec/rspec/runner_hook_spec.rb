# frozen_string_literal: true

require 'set'

require 'rspec_tracer/rspec/runner_hook'

# Unit coverage for RSpecTracer::RSpec::RunnerHook. Uses an anonymous
# class for the prepend target so installation onto the real
# RSpec::Core::Runner (which already happened at spec_helper load
# time) doesn't leak into the assertions.
#
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/VerifiedDoubles
# rubocop:disable RSpec/MultipleMemoizedHelpers, Style/MultilineBlockChain
RSpec.describe RSpecTracer::RSpec::RunnerHook do
  let(:runner_class) do
    Class.new do
      attr_reader :super_calls

      def initialize
        @super_calls = []
      end

      def run_specs(example_groups)
        @super_calls << example_groups
        :super_result
      end
    end.tap { |c| c.prepend(described_class) }
  end

  let(:runner)     { runner_class.new }
  let(:engine)     { double('Engine') }
  let(:logger)     { spy('logger') }
  let(:world)      { double('RSpec.world') }

  let(:example_group) { double('ExampleGroup') }
  let(:example_metadata) { { file_path: 'spec/foo_spec.rb' } }
  let(:example) do
    double('Example', object_id: 1001, metadata: example_metadata, description: 'does things',
                      example_group: double('EG', parent_groups: [example_group]))
  end
  let(:tracer_example) { { example_id: 'ex1' } }

  before do
    allow(RSpec).to receive(:world).and_return(world)
    allow(RSpecTracer).to receive(:running=)
    allow(RSpecTracer).to receive(:no_examples=)
    allow(RSpecTracer).to receive(:duplicate_examples=)
    allow(RSpecTracer).to receive_messages(engine: engine, logger: logger, fail_on_duplicates: false,
                                           ignore_spec_file?: false)
    allow(RSpecTracer::Example).to receive(:from).and_return(tracer_example)
    allow(RSpecTracer::RSpec::Metadata).to receive(:tracks_for).and_return(files: Set.new, env: Set.new)
    allow(engine).to receive_messages(run_example?: true, run_example_reason: 'No cache',
                                      duplicate_examples: {})
    allow(engine).to receive(:register_example)
    allow(engine).to receive(:register_tracks)
    allow(engine).to receive(:apply_env_filter_decisions)
    allow(engine).to receive(:on_example_skipped)
    allow(engine).to receive(:deregister_duplicate_examples)
  end

  describe '#run_specs' do
    context 'when the engine is absent (graceful degrade)' do
      before { allow(RSpecTracer).to receive(:engine).and_return(nil) }

      it 'calls super directly without touching RSpec.world' do
        allow(world).to receive(:example_count).and_return(42) # unused in this path

        result = runner.run_specs([:group1])

        expect(result).to eq(:super_result)
        expect(runner.super_calls).to eq([[:group1]])
      end
    end

    context 'when there are zero examples' do
      before { allow(world).to receive(:example_count).and_return(0) }

      it 'flips the no_examples + running flags and forwards to super unchanged' do
        runner.run_specs([:group_a])

        expect(RSpecTracer).to have_received(:running=).with(true)
        expect(RSpecTracer).to have_received(:no_examples=).with(true)
        expect(runner.super_calls).to eq([[:group_a]])
      end
    end

    context 'when duplicate examples are detected' do
      let(:colliding_metadata) { { file_path: 'spec/user_spec.rb' } }
      let(:unique_metadata) { { file_path: 'spec/user_spec.rb' } }
      let(:colliding_example) do
        double('CollidingExample', metadata: colliding_metadata, description: 'collides',
                                   example_group: double('EG', parent_groups: [example_group]))
      end
      let(:unique_example) do
        double('UniqueExample', metadata: unique_metadata, description: 'is unique',
                                example_group: double('EG', parent_groups: [example_group]))
      end
      let(:duplicate_entries) do
        [
          { example_id: 'dup-id', file_name: 'spec/user_spec.rb', line_number: 6,
            full_description: 'User is valid' },
          { example_id: 'dup-id', file_name: 'spec/user_spec.rb', line_number: 7,
            full_description: 'User is valid' }
        ]
      end

      before do
        allow(world).to receive(:example_count).and_return(2, 1)
        allow(world).to receive(:filtered_examples)
          .and_return(example_group => [colliding_example, unique_example])
        allow(world).to receive(:instance_variable_set)
        allow(RSpecTracer::Example).to receive(:from).with(colliding_example)
          .and_return(example_id: 'dup-id')
        allow(RSpecTracer::Example).to receive(:from).with(unique_example)
          .and_return(example_id: 'unique-id')
        allow(engine).to receive(:duplicate_examples).and_return('dup-id' => duplicate_entries)
        allow(RSpecTracer).to receive(:fail_on_duplicates).and_return(true)
      end

      it 'logs the summary line, the identity hash, the colliding examples, and a remediation hint' do
        runner.run_specs([:original])

        expect(logger).to have_received(:error).with(
          a_string_including('2 duplicate example(s) across 1 identity hash(es)')
            .and(a_string_including('dup-id'))
            .and(a_string_including('spec/user_spec.rb:6 User is valid'))
            .and(a_string_including('spec/user_spec.rb:7 User is valid'))
            .and(a_string_including('distinct descriptions'))
        )
      end

      it 'flips RSpecTracer.duplicate_examples to the fail_on_duplicates value' do
        runner.run_specs([:original])

        expect(RSpecTracer).to have_received(:duplicate_examples=).with(true)
      end

      it 'drops only the colliding examples and still runs the rest of the suite' do
        runner.run_specs([:original])

        expect(world).to have_received(:instance_variable_set)
          .with(:@filtered_examples, example_group => [unique_example])
        expect(runner.super_calls.last).to eq([example_group])
      end

      it 'drops a group entirely when every one of its examples collides' do
        allow(world).to receive(:filtered_examples).and_return(example_group => [colliding_example])

        runner.run_specs([:original])

        expect(world).to have_received(:instance_variable_set).with(:@filtered_examples, {})
        expect(world).to have_received(:instance_variable_set).with(:@example_groups, [])
        expect(runner.super_calls.last).to eq([])
      end

      it 'labels a colliding example file:line description, preferring the rerun location' do
        label = runner.send(
          :_rspec_tracer_example_label,
          rerun_file_name: 'spec/a_spec.rb', rerun_line_number: 9,
          file_name: 'spec/support/shared.rb', line_number: 99,
          full_description: 'Thing behaves like shared '
        )

        expect(label).to eq('spec/a_spec.rb:9 Thing behaves like shared')
      end

      it 'returns a Hash with a default block so intermediate describe groups do not NPE in example_count' do
        # rspec-core's RSpec::Core::World#example_count walks
        # g.descendants for every top-level group and reads
        # e.filtered_examples (= world.filtered_examples[e]) on each
        # descendant. Intermediate groups (a `describe` containing only
        # nested `describe`s, no direct `it`s) have no entry in the
        # kept Hash. A plain Hash returns nil for those keys; the
        # missing-key lookup then NPEs in
        # `inject(0) { |a, e| a + e.filtered_examples.size }`. The
        # default block returns [] (.size == 0) matching what
        # _rspec_tracer_build_filter_decision's to_run already does.
        # Issue: avmnu-sng/rspec-tracer#218.
        surviving_metadata = { rspec_tracer_example_id: 'unique-id', file_path: 'spec/a_spec.rb' }
        leaf_group = double('LeafGroup')
        survivor = double('Survivor', metadata: surviving_metadata, description: 'unique',
                                      example_group: double('EG', parent_groups: [leaf_group]))
        intermediate_group = double('IntermediateGroup')
        allow(engine).to receive(:duplicate_examples)
          .and_return('dup-id' => duplicate_entries)
        examples_map = { leaf_group => [survivor] }

        kept_map, kept_groups = runner.send(
          :_rspec_tracer_drop_duplicate_examples, examples_map, [leaf_group]
        )

        expect(kept_map[leaf_group]).to eq([survivor])
        expect(kept_groups).to eq([leaf_group])
        # Load-bearing assertion: missing-key lookup returns [] not nil.
        expect(kept_map.default_proc).not_to be_nil
        expect(kept_map[intermediate_group]).to eq([])
      end

      it 'keeps a nested top-level group whose leaf describe still has surviving examples' do
        # RSpec.world.filtered_examples is keyed by LEAF groups while
        # run_specs' group list holds TOP-LEVEL groups
        # (`example.example_group.parent_groups.last`). For any spec
        # file with nested describes those two sets are disjoint, so
        # the drop path must map survivors back to their top-level
        # parent instead of requiring the top-level group to be a
        # kept_map key. Regression: with one colliding pair anywhere
        # in the suite, every nested spec file was dropped wholesale
        # (refinery soak: "running 68 examples (actual: 399,
        # skipped: 331)").
        top_group = double('TopLevelGroup')
        leaf_group = double('LeafGroup')
        survivor_metadata = { rspec_tracer_example_id: 'unique-id', file_path: 'spec/a_spec.rb' }
        survivor = double('Survivor', metadata: survivor_metadata, description: 'unique',
                                      example_group: double('EG', parent_groups: [leaf_group, top_group]))
        examples_map = { leaf_group => [survivor] }

        kept_map, kept_groups = runner.send(
          :_rspec_tracer_drop_duplicate_examples, examples_map, [top_group]
        )

        expect(kept_map[leaf_group]).to eq([survivor])
        expect(kept_groups).to eq([top_group])
      end
    end

    context 'when examples are tracked and the engine schedules a run' do
      before do
        allow(world).to receive(:example_count).and_return(2, 1)
        allow(world).to receive(:filtered_examples).and_return(example_group => [example])
        allow(world).to receive(:instance_variable_set)
      end

      it 'registers the example, updates metadata, and delegates to super with the filtered set' do
        runner.run_specs([])

        expect(engine).to have_received(:register_example).with(hash_including(run_reason: 'No cache'))
        expect(example_metadata).to include(rspec_tracer_example_id: 'ex1')
        expect(example_metadata[:description]).to include('(No cache)')
        expect(world).to have_received(:instance_variable_set)
          .with(:@filtered_examples, hash_including(example_group => [example]))
        expect(world).to have_received(:instance_variable_set)
          .with(:@example_groups, [example_group])
        expect(runner.super_calls.last).to eq([example_group])
        expect(logger).to have_received(:info).with(/RSpec tracer is running 1 examples/)
      end
    end

    context 'when the engine filters an example out' do
      before do
        allow(world).to receive(:example_count).and_return(1, 0)
        allow(world).to receive(:filtered_examples).and_return(example_group => [example])
        allow(world).to receive(:instance_variable_set)
        allow(engine).to receive(:run_example?).with('ex1').and_return(false)
      end

      it 'notifies the engine of the skip and does not call register_example' do
        runner.run_specs([])

        expect(engine).to have_received(:on_example_skipped).with('ex1')
        expect(engine).not_to have_received(:register_example)
      end
    end

    context 'when per-example tracks metadata is present' do
      before do
        allow(world).to receive(:example_count).and_return(1, 1)
        allow(world).to receive(:filtered_examples).and_return(example_group => [example])
        allow(world).to receive(:instance_variable_set)
      end

      it 'registers non-empty tracks metadata on the engine (Pass 1)' do
        allow(RSpecTracer::RSpec::Metadata).to receive(:tracks_for).with(example).and_return(
          files: Set.new(['config/*.yml']), env: Set.new(['API_KEY'])
        )

        runner.run_specs([])

        expect(engine).to have_received(:register_tracks)
          .with('ex1', hash_including(files: Set.new(['config/*.yml']), env: Set.new(['API_KEY'])))
      end

      it 'skips register_tracks when both tracks sets are empty' do
        runner.run_specs([])

        expect(engine).not_to have_received(:register_tracks)
      end

      it 'invokes apply_env_filter_decisions between the two passes' do
        runner.run_specs([])

        expect(engine).to have_received(:apply_env_filter_decisions)
      end

      it 'does not read tracks for ignored spec files' do
        allow(RSpecTracer).to receive(:ignore_spec_file?).with('spec/foo_spec.rb').and_return(true)

        runner.run_specs([])

        expect(RSpecTracer::RSpec::Metadata).not_to have_received(:tracks_for)
        expect(engine).not_to have_received(:register_tracks)
      end

      it 'computes Example.from only once per example (Pass 1 caches into Pass 2)' do
        runner.run_specs([])

        expect(RSpecTracer::Example).to have_received(:from).once
      end
    end

    context 'when an example matches ignore_spec_files' do
      before do
        allow(RSpecTracer).to receive(:ignore_spec_file?).with('spec/foo_spec.rb').and_return(true)
        allow(world).to receive(:example_count).and_return(1, 1)
        allow(world).to receive(:filtered_examples).and_return(example_group => [example])
        allow(world).to receive(:instance_variable_set)
      end

      it 'passes the example through without registering or hashing it' do
        runner.run_specs([])

        expect(RSpecTracer::Example).not_to have_received(:from)
        expect(engine).not_to have_received(:register_example)
        expect(engine).not_to have_received(:on_example_skipped)
        expect(example_metadata).not_to include(:rspec_tracer_example_id)
        expect(world).to have_received(:instance_variable_set)
          .with(:@filtered_examples, hash_including(example_group => [example]))
      end
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/VerifiedDoubles
# rubocop:enable RSpec/MultipleMemoizedHelpers, Style/MultilineBlockChain
