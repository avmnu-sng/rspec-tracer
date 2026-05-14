# frozen_string_literal: true

require 'set'
require 'rspec_tracer/storage/lazy_snapshot'
require 'rspec_tracer/storage/snapshot'

# rubocop:disable RSpec/MultipleExpectations
RSpec.describe RSpecTracer::Storage::LazySnapshot do
  let(:reader_class) do
    Class.new do
      attr_reader :read_fields

      def initialize(values)
        @values = values
        @read_fields = []
      end

      def read(field)
        @read_fields << field
        @values.fetch(field)
      end
    end
  end

  let(:field_values) do
    {
      all_examples: { 'ex1' => { id: 'ex1' } },
      duplicate_examples: {},
      interrupted_examples: Set.new,
      flaky_examples: Set.new,
      failed_examples: Set.new,
      pending_examples: Set.new,
      skipped_examples: Set.new,
      all_files: { '/a.rb' => { file_name: '/a.rb' } },
      dependency: { 'ex1' => Set.new(['/a.rb']) },
      reverse_dependency: { '/a.rb' => Set.new(['ex1']) },
      examples_coverage: {},
      boot_set: {},
      wsi_snapshot: {},
      env_snapshot: {},
      env_dependency: {},
      cache_hit_reason: {},
      filtered_examples: {}
    }
  end

  let(:reader)   { reader_class.new(field_values) }
  let(:snapshot) { described_class.new(schema_version: 3, run_id: 'abc', reader: reader) }

  describe 'eager members' do
    it 'exposes schema_version without touching the reader' do
      expect(snapshot.schema_version).to eq(3)
      expect(reader.read_fields).to be_empty
    end

    it 'exposes run_id without touching the reader' do
      expect(snapshot.run_id).to eq('abc')
      expect(reader.read_fields).to be_empty
    end
  end

  describe 'lazy fields' do
    it 'reads a field on first access' do
      snapshot.dependency
      expect(reader.read_fields).to eq([:dependency])
    end

    it 'does not read a field the caller never touches' do
      snapshot.all_examples
      snapshot.all_files
      expect(reader.read_fields).to contain_exactly(:all_examples, :all_files)
    end

    it 'memoizes a field - second access does not re-read' do
      snapshot.dependency
      snapshot.dependency
      expect(reader.read_fields).to eq([:dependency])
    end

    it 'returns the reader-provided value' do
      expect(snapshot.dependency).to eq('ex1' => Set.new(['/a.rb']))
    end
  end

  describe '#to_h' do
    it 'materializes every field' do
      snapshot.to_h
      expect(reader.read_fields).to match_array(described_class::LAZY_FIELDS)
    end

    it 'returns a Hash keyed by Snapshot member names' do
      expect(snapshot.to_h.keys).to match_array(RSpecTracer::Storage::Snapshot.members)
    end

    it 'carries schema_version and run_id as eager members' do
      result = snapshot.to_h
      expect(result[:schema_version]).to eq(3)
      expect(result[:run_id]).to eq('abc')
    end
  end

  describe '#to_snapshot' do
    it 'returns a Storage::Snapshot carrying the same values' do
      eager = snapshot.to_snapshot
      expect(eager).to be_a(RSpecTracer::Storage::Snapshot)
      expect(eager.dependency).to eq('ex1' => Set.new(['/a.rb']))
      expect(eager.run_id).to eq('abc')
    end
  end

  describe 'LAZY_FIELDS constant' do
    it 'contains every Snapshot member except schema_version and run_id' do
      expected = RSpecTracer::Storage::Snapshot.members - %i[schema_version run_id]
      expect(described_class::LAZY_FIELDS).to eq(expected)
    end

    it 'is frozen' do
      expect(described_class::LAZY_FIELDS).to be_frozen
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations
