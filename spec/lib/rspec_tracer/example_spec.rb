# frozen_string_literal: true

require 'spec_helper'

# Unit coverage for RSpecTracer::Example.from — the identity-hash
# payload builder. example_id must be stable across runs (issue #196:
# load-order-dependent class names; issue #210: line-bearing
# description fallback for unnamed examples) so the cache lookup hits
# the prior run's entry for the same logical example. line_number /
# rerun_* still ride along in the returned Hash for the reporter's
# location columns but are excluded from the digest.
#
# rubocop:disable RSpec/VerifiedDoubles, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe RSpecTracer::Example do
  # An RSpec::Core::Example-shaped double. `raw_description` is
  # metadata[:description] — RSpec's RAW explicit description ('' or
  # nil for an unnamed `it { } / specify { } / example { }`); defaults
  # to `description`, so a plain `build_example` models a NAMED
  # example. `siblings` overrides example_group.examples (default
  # [self]) so the unnamed-example ordinal can be taken.
  def build_example(overrides = {})
    opts = {
      group_description: 'Calculator', parent_groups: [],
      description: 'adds two numbers', full_description: 'Calculator adds two numbers',
      file_path: '/proj/spec/calculator_spec.rb', rerun_file_path: nil,
      line_number: 7, shared_backtrace: []
    }.merge(overrides)
    raw_description = overrides.key?(:raw_description) ? overrides[:raw_description] : opts[:description]
    example_group = double(
      'ExampleGroup', description: opts[:group_description], parent_groups: opts[:parent_groups]
    )
    example = double(
      'Example',
      example_group: example_group,
      description: opts[:description],
      full_description: opts[:full_description],
      metadata: {
        description: raw_description,
        file_path: opts[:file_path],
        rerun_file_path: opts[:rerun_file_path] || opts[:file_path],
        line_number: opts[:line_number],
        shared_group_inclusion_backtrace: opts[:shared_backtrace]
      }
    )
    allow(example_group).to receive(:examples).and_return(overrides[:siblings] || [example])
    example
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

  # Builds N example doubles sharing one example_group. Each
  # `raw_descriptions` entry is one example's metadata[:description]
  # ('' / nil => unnamed). Every example's example_group.examples is
  # the full ordered list so unnamed-example ordinal lookup works.
  # `line_base` shifts every line uniformly (no-op-edit simulation).
  def build_group(raw_descriptions, group_description: 'G', file_path: '/proj/spec/g_spec.rb', line_base: 0)
    examples = []
    example_group = double('ExampleGroup', description: group_description, parent_groups: [])
    allow(example_group).to receive(:examples).and_return(examples)
    raw_descriptions.each_with_index do |raw, idx|
      line = line_base + ((idx + 1) * 10)
      unnamed = raw.to_s.strip.empty?
      examples << double(
        "Example#{idx}",
        example_group: example_group,
        description: unnamed ? "example at #{file_path}:#{line}" : raw,
        full_description: unnamed ? "#{group_description} " : "#{group_description} #{raw}",
        metadata: {
          description: raw,
          file_path: file_path,
          rerun_file_path: file_path,
          line_number: line,
          shared_group_inclusion_backtrace: []
        }
      )
    end
    examples
  end

  # Reset the unnamed-siblings memo between contexts that share
  # group-description / sibling layouts but want fresh cache state.
  def reset_unnamed_cache!
    described_class.instance_variable_set(:@unnamed_siblings_cache, {}.compare_by_identity)
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

    it 'passes description / full_description through unchanged' do
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
  end

  describe '.from example_group identity (the #196 fix)' do
    it 'reads example_group.description (the user-supplied string)' do
      result = described_class.from(build_example(group_description: 'PaymentGateway'))

      expect(result[:example_group]).to eq('PaymentGateway')
    end

    it 'never reads example_group.name (RSpec load-order-dependent class name)' do
      # The group double responds to :description only; a
      # `.description` -> `.name` regression in `from` raises an
      # unexpected-message error here.
      expect { described_class.from(build_example) }.not_to raise_error
    end

    it 'produces the same id for two examples sharing a group description across files' do
      a = described_class.from(build_example(group_description: 'User', file_path: '/proj/spec/user_spec.rb'))
      b = described_class.from(build_example(group_description: 'User', file_path: '/proj/spec/user_spec.rb'))

      expect(a[:example_id]).to eq(b[:example_id])
    end

    it 'produces a different id when the group description differs (rename = new identity)' do
      a = described_class.from(build_example(group_description: 'User'))
      b = described_class.from(build_example(group_description: 'Account'))

      expect(a[:example_id]).not_to eq(b[:example_id])
    end
  end

  describe '.from shared_group inclusion frames' do
    it 'strips the trailing :LINE from each frame location' do
      result = described_class.from(
        build_example(shared_backtrace: [shared_frame('./spec/support/shared.rb:53')])
      )

      expect(result[:shared_group]).to eq(['./spec/support/shared.rb'])
    end

    it 'is stable when shared_group frames differ only in their :LINE' do
      at53 = described_class.from(build_example(shared_backtrace: [shared_frame('./spec/s.rb:53')]))
      at99 = described_class.from(build_example(shared_backtrace: [shared_frame('./spec/s.rb:99')]))

      expect(at53[:example_id]).to eq(at99[:example_id])
    end

    it 'is an empty array when the example uses no shared groups' do
      expect(described_class.from(build_example)[:shared_group]).to eq([])
    end
  end

  describe '.from digest EXCLUDES line numbers (the #196 named-example fix)' do
    it 'is stable when only line_number shifts (no-op edit above the example)' do
      expect(described_class.from(build_example(line_number: 7))[:example_id])
        .to eq(described_class.from(build_example(line_number: 99))[:example_id])
    end
  end

  describe '.from unnamed examples (the #210 fix)' do
    before { reset_unnamed_cache! }

    it 'is stable when only line_number shifts (line-shift no-op for an unnamed example)' do
      siblings = build_group(['', ''], line_base: 0)
      first_lined = described_class.from(siblings.first)

      reset_unnamed_cache!
      shifted = build_group(['', ''], line_base: 50)
      first_shifted = described_class.from(shifted.first)

      expect(first_lined[:example_id]).to eq(first_shifted[:example_id])
    end

    it 'N unnamed siblings produce N DISTINCT ids (within-group uniqueness)' do
      siblings = build_group(['', '', ''])
      ids = siblings.map { |s| described_class.from(s)[:example_id] }

      expect(ids.uniq.size).to eq(3)
    end

    it 'is stable when a named sibling is added or renamed alongside the unnamed example' do
      mixed_a = build_group(['', 'named one'])
      reset_unnamed_cache!
      mixed_b = build_group(['', 'renamed'])

      expect(described_class.from(mixed_a.first)[:example_id])
        .to eq(described_class.from(mixed_b.first)[:example_id])
    end

    it 'CHANGES when an unnamed example is inserted ahead of it (documented carve-out)' do
      original = build_group(['', ''])
      trailing_id = described_class.from(original[1])[:example_id]

      reset_unnamed_cache!
      with_inserted = build_group(['', '', ''])
      # The original "trailing" unnamed went from ordinal 1 to
      # ordinal 2 — different positional discriminator, different id.
      shifted_trailing_id = described_class.from(with_inserted[2])[:example_id]

      expect(trailing_id).not_to eq(shifted_trailing_id)
    end

    it 'gives the unnamed-example digest a Ruby-inspect-style discriminator' do
      siblings = build_group(['', ''])

      # Probe the private helper directly to lock in the format.
      probe = described_class.send(:unnamed_description, siblings.first)
      expect(probe).to eq('#<rspec-tracer unnamed example 0>')
    end
  end

  describe '.from cross-file rerun location' do
    it 'walks parent_groups for the rerun location when example file differs from rerun file' do
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
  end
end
# rubocop:enable RSpec/VerifiedDoubles, RSpec/MultipleExpectations, RSpec/ExampleLength
