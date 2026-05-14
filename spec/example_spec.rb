# frozen_string_literal: true

require 'rspec_tracer'

# Unit coverage for RSpecTracer::Example.from — the identity-hash
# payload builder. The load-bearing contract (see the module's
# stability-contract YARD comment in lib/rspec_tracer/example.rb):
# example_id is the MD5 of a STABLE SUBSET of the payload
# (example_group description, description, full_description,
# line-stripped shared_group, file_name). line_number / rerun_*
# ride along in the returned Hash for the reporter + `explain`
# location columns but are excluded from the digest, so a no-op
# line-shifting edit must not flip the id (issue #196).
#
# rubocop:disable RSpec/VerifiedDoubles, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe RSpecTracer::Example do
  # An RSpec::Core::Example-shaped double. The overrides Hash lets
  # each test vary exactly one identity input (engine_spec's
  # stub_configuration pattern). The example_group double responds
  # to `description` but NOT `name`: `from` must read `.description`,
  # and a `.description` -> `.name` mutation raises here.
  def build_example(overrides = {})
    opts = {
      group_description: 'Calculator', parent_groups: [],
      description: 'adds two numbers',
      full_description: 'Calculator adds two numbers',
      file_path: '/proj/spec/calculator_spec.rb', rerun_file_path: nil,
      line_number: 7, shared_backtrace: []
    }.merge(overrides)

    example_group = double(
      'ExampleGroup', description: opts[:group_description], parent_groups: opts[:parent_groups]
    )
    double(
      'Example',
      example_group: example_group,
      description: opts[:description],
      full_description: opts[:full_description],
      metadata: {
        file_path: opts[:file_path],
        rerun_file_path: opts[:rerun_file_path] || opts[:file_path],
        line_number: opts[:line_number],
        shared_group_inclusion_backtrace: opts[:shared_backtrace]
      }
    )
  end

  def build_parent_group(file_path:, line_number:, rerun_file_path: nil)
    double(
      'ParentGroup',
      metadata: {
        file_path: file_path,
        rerun_file_path: rerun_file_path || file_path,
        line_number: line_number
      }
    )
  end

  def shared_frame(location)
    double('SharedFrame', formatted_inclusion_location: location)
  end

  describe '.from payload shape' do
    it 'returns the canonical 9-key identity-hash shape' do
      expect(described_class.from(build_example)).to include(
        :example_group, :description, :full_description, :shared_group,
        :file_name, :line_number, :rerun_file_name, :rerun_line_number, :example_id
      )
    end

    it 'computes example_id as a 32-char hex MD5' do
      expect(described_class.from(build_example)[:example_id]).to match(/\A[0-9a-f]{32}\z/)
    end

    it 'is deterministic for the same example across calls' do
      first = described_class.from(build_example)
      second = described_class.from(build_example)

      expect(first[:example_id]).to eq(second[:example_id])
    end

    it 'passes description and full_description through unchanged' do
      result = described_class.from(build_example(description: 'd', full_description: 'g d'))

      expect(result[:description]).to eq('d')
      expect(result[:full_description]).to eq('g d')
    end

    it 'carries line_number / rerun_* through to the returned Hash (reporter columns)' do
      result = described_class.from(build_example(line_number: 42))

      expect(result[:line_number]).to eq(42)
      expect(result[:rerun_line_number]).to eq(42)
      expect(result[:rerun_file_name]).to eq(result[:file_name])
    end

    it 'derives file_name from the example metadata file_path' do
      result = described_class.from(build_example(file_path: '/proj/spec/widget_spec.rb'))

      expect(result[:file_name]).to eq('/proj/spec/widget_spec.rb')
    end
  end

  describe '.from example_group identity' do
    it 'reads example_group.description (the user-supplied string)' do
      result = described_class.from(build_example(group_description: 'PaymentGateway'))

      expect(result[:example_group]).to eq('PaymentGateway')
    end

    it 'does not read example_group.name (RSpec load-order-dependent class name — issue #196)' do
      # build_example's group double responds to :description only;
      # a `.description` -> `.name` mutation raises an unexpected-message
      # error here, killing the mutation.
      expect { described_class.from(build_example) }.not_to raise_error
    end
  end

  describe '.from shared_group inclusion frames' do
    it 'strips the trailing :LINE from each frame location' do
      result = described_class.from(
        build_example(shared_backtrace: [shared_frame('./spec/support/shared.rb:53')])
      )

      expect(result[:shared_group]).to eq(['./spec/support/shared.rb'])
    end

    it 'strips every frame in a multi-frame backtrace' do
      frames = [shared_frame('./spec/support/a.rb:1'), shared_frame('./spec/support/b.rb:200')]
      result = described_class.from(build_example(shared_backtrace: frames))

      expect(result[:shared_group]).to eq(['./spec/support/a.rb', './spec/support/b.rb'])
    end

    it 'is an empty array when the example uses no shared groups' do
      expect(described_class.from(build_example)[:shared_group]).to eq([])
    end

    it 'leaves a frame location with no trailing :LINE untouched' do
      result = described_class.from(
        build_example(shared_backtrace: [shared_frame('./spec/support/shared.rb')])
      )

      expect(result[:shared_group]).to eq(['./spec/support/shared.rb'])
    end
  end

  describe '.from cross-file rerun location' do
    it 'walks parent_groups for the rerun location when the example file differs from its rerun file' do
      host = build_parent_group(file_path: '/proj/spec/host_spec.rb', line_number: 12)
      result = described_class.from(build_example(
                                      file_path: '/proj/spec/support/shared_widgets.rb',
                                      rerun_file_path: '/proj/spec/host_spec.rb',
                                      parent_groups: [host]
                                    ))

      expect(result[:file_name]).to eq('/proj/spec/support/shared_widgets.rb')
      expect(result[:rerun_file_name]).to eq('/proj/spec/host_spec.rb')
      expect(result[:rerun_line_number]).to eq(12)
    end

    it 'skips parent groups whose file does not match the rerun file' do
      outer = build_parent_group(
        file_path: '/proj/spec/other_spec.rb', rerun_file_path: '/proj/spec/elsewhere.rb', line_number: 3
      )
      host = build_parent_group(file_path: '/proj/spec/host_spec.rb', line_number: 12)
      result = described_class.from(build_example(
                                      file_path: '/proj/spec/support/shared_widgets.rb',
                                      rerun_file_path: '/proj/spec/host_spec.rb',
                                      parent_groups: [outer, host]
                                    ))

      expect(result[:rerun_file_name]).to eq('/proj/spec/host_spec.rb')
      expect(result[:rerun_line_number]).to eq(12)
    end
  end

  describe '.from digest EXCLUDES line numbers (the #196 fix)' do
    it 'is stable when only line_number shifts (no-op edit above the example)' do
      expect(described_class.from(build_example(line_number: 7))[:example_id])
        .to eq(described_class.from(build_example(line_number: 99))[:example_id])
    end

    it 'is stable when shared_group frames differ only in their :LINE' do
      at53 = described_class.from(build_example(shared_backtrace: [shared_frame('./spec/s.rb:53')]))
      at99 = described_class.from(build_example(shared_backtrace: [shared_frame('./spec/s.rb:99')]))

      expect(at53[:example_id]).to eq(at99[:example_id])
    end
  end

  describe '.from digest INCLUDES every identity field' do
    it 'changes when example_group changes' do
      expect(described_class.from(build_example(group_description: 'A'))[:example_id])
        .not_to eq(described_class.from(build_example(group_description: 'B'))[:example_id])
    end

    it 'changes when description changes' do
      expect(described_class.from(build_example(description: 'does X'))[:example_id])
        .not_to eq(described_class.from(build_example(description: 'does Y'))[:example_id])
    end

    it 'changes when full_description changes' do
      expect(described_class.from(build_example(full_description: 'G does X'))[:example_id])
        .not_to eq(described_class.from(build_example(full_description: 'G does Y'))[:example_id])
    end

    it 'changes when file_name changes (file rename / move)' do
      expect(described_class.from(build_example(file_path: '/proj/spec/old_spec.rb'))[:example_id])
        .not_to eq(described_class.from(build_example(file_path: '/proj/spec/new_spec.rb'))[:example_id])
    end

    it 'changes when a shared_group inclusion path changes' do
      a = described_class.from(build_example(shared_backtrace: [shared_frame('./spec/a.rb:1')]))
      b = described_class.from(build_example(shared_backtrace: [shared_frame('./spec/b.rb:1')]))

      expect(a[:example_id]).not_to eq(b[:example_id])
    end
  end

  describe '.from describe-block edge cases' do
    it 'handles a class describe — description is the coerced class name' do
      result = described_class.from(build_example(group_description: 'String'))

      expect(result[:example_group]).to eq('String')
      expect(result[:example_id]).to match(/\A[0-9a-f]{32}\z/)
    end

    it 'handles an anonymous describe — description is empty — without crashing' do
      result = described_class.from(build_example(group_description: ''))

      expect(result[:example_group]).to eq('')
      expect(result[:example_id]).to match(/\A[0-9a-f]{32}\z/)
    end

    it 'still differentiates anonymous-describe examples via full_description' do
      a = described_class.from(build_example(group_description: '', full_description: 'anon does X'))
      b = described_class.from(build_example(group_description: '', full_description: 'anon does Y'))

      expect(a[:example_id]).not_to eq(b[:example_id])
    end
  end
end
# rubocop:enable RSpec/VerifiedDoubles, RSpec/MultipleExpectations, RSpec/ExampleLength
