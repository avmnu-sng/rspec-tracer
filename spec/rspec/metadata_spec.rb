# frozen_string_literal: true

require 'set'
require 'rspec_tracer/rspec/metadata'

# rubocop:disable RSpec/MultipleExpectations, RSpec/VerifiedDoubles, RSpec/ExampleLength
RSpec.describe RSpecTracer::RSpec::Metadata do
  # Build minimal test doubles for the RSpec metadata walk. Real
  # RSpec::Core::ExampleGroup instances require a configuration +
  # subclass dance that is overkill for unit coverage of the walker.
  # The walker only reads `example.example_group.parent_groups` and
  # `group.metadata[:tracks]` - both trivially fakeable.
  let(:grandparent) { fake_group(tracks: nil) }
  let(:parent) { fake_group(tracks: nil) }
  let(:child) { fake_group(tracks: nil) }

  def fake_group(tracks:)
    double('ExampleGroup', metadata: { tracks: tracks })
  end

  def fake_example(tracks:, parent_groups:)
    group_double = double('ExampleGroup', parent_groups: parent_groups)
    double('Example', example_group: group_double, metadata: { tracks: tracks })
  end

  describe '.tracks_for' do
    it 'returns empty sets when no tracks metadata anywhere' do
      example = fake_example(tracks: nil, parent_groups: [parent, grandparent])

      result = described_class.tracks_for(example)

      expect(result[:files]).to eq(Set.new)
      expect(result[:env]).to eq(Set.new)
    end

    it 'reads a single-string :files value' do
      example = fake_example(
        tracks: { files: 'app/policies/**/*.rb' },
        parent_groups: [parent]
      )
      allow(parent).to receive(:metadata).and_return({})

      result = described_class.tracks_for(example)

      expect(result[:files]).to eq(Set.new(['app/policies/**/*.rb']))
    end

    it 'reads an array :files value' do
      example = fake_example(
        tracks: { files: %w[a/*.rb b/*.rb] },
        parent_groups: []
      )

      result = described_class.tracks_for(example)

      expect(result[:files]).to eq(Set.new(%w[a/*.rb b/*.rb]))
    end

    it 'reads a single-string :env value' do
      example = fake_example(tracks: { env: 'API_KEY' }, parent_groups: [])

      result = described_class.tracks_for(example)

      expect(result[:env]).to eq(Set.new(['API_KEY']))
    end

    it 'reads an array :env value' do
      example = fake_example(tracks: { env: %w[API_KEY ROLE_CONFIG] }, parent_groups: [])

      result = described_class.tracks_for(example)

      expect(result[:env]).to eq(Set.new(%w[API_KEY ROLE_CONFIG]))
    end

    it 'unions (not replaces) file globs across parent-group hierarchy' do
      allow(grandparent).to receive(:metadata).and_return(tracks: { files: 'gp/**/*' })
      allow(parent).to receive(:metadata).and_return(tracks: { files: 'p/**/*' })
      example = fake_example(
        tracks: { files: 'e/**/*' },
        parent_groups: [parent, grandparent]
      )

      result = described_class.tracks_for(example)

      expect(result[:files]).to eq(Set.new(%w[gp/**/* p/**/* e/**/*]))
    end

    it 'unions env names across parent-group hierarchy' do
      allow(grandparent).to receive(:metadata).and_return(tracks: { env: 'ONE' })
      allow(parent).to receive(:metadata).and_return(tracks: { env: %w[TWO THREE] })
      example = fake_example(
        tracks: { env: 'FOUR' },
        parent_groups: [parent, grandparent]
      )

      result = described_class.tracks_for(example)

      expect(result[:env]).to eq(Set.new(%w[ONE TWO THREE FOUR]))
    end

    it 'unions both files and env from a mixed hierarchy' do
      allow(parent).to receive(:metadata).and_return(tracks: { files: 'p/*.rb' })
      example = fake_example(
        tracks: { env: 'API_KEY' },
        parent_groups: [parent]
      )

      result = described_class.tracks_for(example)

      expect(result[:files]).to eq(Set.new(['p/*.rb']))
      expect(result[:env]).to eq(Set.new(['API_KEY']))
    end

    it 'ignores a non-Hash :tracks value' do
      example = fake_example(tracks: 'not a hash', parent_groups: [])

      result = described_class.tracks_for(example)

      expect(result[:files]).to eq(Set.new)
      expect(result[:env]).to eq(Set.new)
    end

    it 'ignores a non-Hash :tracks on an ancestor group' do
      allow(parent).to receive(:metadata).and_return(tracks: 42)
      example = fake_example(tracks: { files: 'a/*' }, parent_groups: [parent])

      result = described_class.tracks_for(example)

      expect(result[:files]).to eq(Set.new(['a/*']))
    end

    it 'filters out empty-string entries from an array value' do
      example = fake_example(tracks: { files: ['a/*.rb', ''] }, parent_groups: [])

      result = described_class.tracks_for(example)

      expect(result[:files]).to eq(Set.new(['a/*.rb']))
    end

    it 'treats an empty-string single value as no-op' do
      example = fake_example(tracks: { files: '' }, parent_groups: [])

      result = described_class.tracks_for(example)

      expect(result[:files]).to eq(Set.new)
    end

    it 'coerces non-String array entries via to_s' do
      example = fake_example(tracks: { env: [:API_KEY] }, parent_groups: [])

      result = described_class.tracks_for(example)

      expect(result[:env]).to eq(Set.new(['API_KEY']))
    end

    it 'ignores Integer or other non-Array non-String values' do
      example = fake_example(tracks: { files: 42, env: nil }, parent_groups: [])

      result = described_class.tracks_for(example)

      expect(result[:files]).to eq(Set.new)
      expect(result[:env]).to eq(Set.new)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/VerifiedDoubles, RSpec/ExampleLength
