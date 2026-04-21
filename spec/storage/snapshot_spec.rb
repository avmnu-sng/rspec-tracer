# frozen_string_literal: true

require 'set'
require 'rspec_tracer/storage/snapshot'

RSpec.describe RSpecTracer::Storage::Snapshot do
  describe '.empty' do
    subject(:snapshot) { described_class.empty(schema_version: 2, run_id: 'run-abc') }

    it 'stamps the schema_version' do
      expect(snapshot.schema_version).to eq(2)
    end

    it 'stamps the run_id' do
      expect(snapshot.run_id).to eq('run-abc')
    end

    it 'defaults Hash-shaped fields to empty Hash' do
      %i[all_examples duplicate_examples all_files dependency reverse_dependency examples_coverage]
        .each { |field| expect(snapshot.send(field)).to eq({}) }
    end

    it 'defaults example-id collections to empty Set' do
      %i[interrupted_examples flaky_examples failed_examples pending_examples skipped_examples]
        .each { |field| expect(snapshot.send(field)).to eq(Set.new) }
    end
  end

  describe 'value semantics' do
    it 'compares equal when every field matches' do
      a = described_class.empty(schema_version: 2, run_id: 'x')
      b = described_class.empty(schema_version: 2, run_id: 'x')

      expect(a).to eq(b)
    end

    it 'differs when run_id differs' do
      a = described_class.empty(schema_version: 2, run_id: 'x')
      b = described_class.empty(schema_version: 2, run_id: 'y')

      expect(a).not_to eq(b)
    end
  end
end
