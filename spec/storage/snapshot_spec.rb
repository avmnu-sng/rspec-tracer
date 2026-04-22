# frozen_string_literal: true

require 'set'
require 'rspec_tracer/storage/snapshot'

RSpec.describe RSpecTracer::Storage::Snapshot do
  describe '.empty' do
    subject(:snapshot) { described_class.empty(schema_version: 3, run_id: 'run-abc') }

    it 'stamps the schema_version' do
      expect(snapshot.schema_version).to eq(3)
    end

    it 'stamps the run_id' do
      expect(snapshot.run_id).to eq('run-abc')
    end

    it 'defaults Hash-shaped fields to empty Hash' do
      %i[
        all_examples duplicate_examples all_files dependency reverse_dependency
        examples_coverage boot_set wsi_snapshot env_snapshot env_dependency
      ].each { |field| expect(snapshot.send(field)).to eq({}) }
    end

    it 'defaults example-id collections to empty Set' do
      %i[interrupted_examples flaky_examples failed_examples pending_examples skipped_examples]
        .each { |field| expect(snapshot.send(field)).to eq(Set.new) }
    end

    it 'defaults boot_set to an empty Hash (schema_version 3 field)' do
      expect(snapshot.boot_set).to eq({})
    end

    it 'defaults wsi_snapshot to an empty Hash (M4.3 field)' do
      expect(snapshot.wsi_snapshot).to eq({})
    end

    it 'defaults env_snapshot to an empty Hash (M5.2 field)' do
      expect(snapshot.env_snapshot).to eq({})
    end

    it 'defaults env_dependency to an empty Hash (M6.1 field)' do
      expect(snapshot.env_dependency).to eq({})
    end
  end

  describe 'value semantics' do
    it 'compares equal when every field matches' do
      a = described_class.empty(schema_version: 3, run_id: 'x')
      b = described_class.empty(schema_version: 3, run_id: 'x')

      expect(a).to eq(b)
    end

    it 'differs when run_id differs' do
      a = described_class.empty(schema_version: 3, run_id: 'x')
      b = described_class.empty(schema_version: 3, run_id: 'y')

      expect(a).not_to eq(b)
    end

    it 'differs when boot_set differs' do
      a = described_class.empty(schema_version: 3, run_id: 'x')
      b = described_class.empty(schema_version: 3, run_id: 'x')
      b.boot_set = { 'lib/a.rb' => 'deadbeef' }

      expect(a).not_to eq(b)
    end

    it 'differs when env_snapshot differs' do
      a = described_class.empty(schema_version: 3, run_id: 'x')
      b = described_class.empty(schema_version: 3, run_id: 'x')
      b.env_snapshot = { 'API_KEY' => 'facade1' }

      expect(a).not_to eq(b)
    end

    it 'differs when env_dependency differs (M6.1)' do
      a = described_class.empty(schema_version: 3, run_id: 'x')
      b = described_class.empty(schema_version: 3, run_id: 'x')
      b.env_dependency = { 'ex1' => ['API_KEY'] }

      expect(a).not_to eq(b)
    end
  end
end
