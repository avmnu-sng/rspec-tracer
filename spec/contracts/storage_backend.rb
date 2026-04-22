# frozen_string_literal: true

require 'set'
require 'rspec_tracer/storage/schema'
require 'rspec_tracer/storage/snapshot'

# Shared-examples contract for RSpecTracer::Storage::Backend
# implementations. Each backend's spec includes these examples with
# `include_examples 'a Storage::Backend'` after binding the following
# `let`s:
#
#   let(:backend)            { described_class.new(...)  }
#   let(:other_backend)      { described_class.new(...)  } # same cache_path
#   let(:sample_snapshot)    { RSpecTracer::Storage::Snapshot.empty(...) }
#
# New backends that break these assertions are not conformant even if
# their own unit tests pass. The contract is behavioral, not
# bytewise - SqliteBackend (M3.8) will include these same examples
# with a very different on-disk layout.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.shared_examples 'a Storage::Backend' do
  describe 'required methods' do
    RSpecTracer::Storage::Backend::REQUIRED_METHODS.each do |method|
      it "responds to :#{method}" do
        expect(backend).to respond_to(method)
      end
    end

    it 'passes Backend.conforms?' do
      expect(RSpecTracer::Storage::Backend.conforms?(backend)).to be(true)
    end
  end

  describe '#last_run_id' do
    it 'returns nil when no cache has been saved' do
      expect(backend.last_run_id).to be_nil
    end

    it 'returns the run_id of the most recent save' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(backend.last_run_id).to eq(sample_snapshot.run_id)
    end
  end

  describe '#load_graph' do
    it 'returns nil when nothing has been saved' do
      expect(backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)).to be_nil
    end

    it 'returns nil on schema_version mismatch' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT + 1)).to be_nil
    end

    it 'round-trips the snapshot when schema matches' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      loaded = other_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(loaded.run_id).to eq(sample_snapshot.run_id)
    end

    it 'returns a Snapshot carrying every field that was saved' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      loaded = other_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      %i[all_examples duplicate_examples interrupted_examples flaky_examples failed_examples
         pending_examples skipped_examples all_files dependency reverse_dependency examples_coverage
         boot_set wsi_snapshot]
        .each { |field| expect(loaded.send(field)).to eq(sample_snapshot.send(field)) }
    end

    it 'does not raise on garbled bytes - returns nil instead' do
      expect { corrupt_backend_storage! }.not_to raise_error

      expect { backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT) }.not_to raise_error
    end
  end

  describe '#save_graph' do
    it 'rejects a nil snapshot' do
      expect { backend.save_graph(nil, schema_version: RSpecTracer::Storage::Schema::CURRENT) }
        .to raise_error(ArgumentError, /snapshot must not be nil/)
    end

    it 'rejects an unsupported schema_version' do
      expect { backend.save_graph(sample_snapshot, schema_version: 9999) }
        .to raise_error(ArgumentError, /schema_version/)
    end

    it 'rejects a snapshot with an empty run_id' do
      empty_id = RSpecTracer::Storage::Snapshot.empty(
        schema_version: RSpecTracer::Storage::Schema::CURRENT, run_id: ''
      )

      expect { backend.save_graph(empty_id, schema_version: RSpecTracer::Storage::Schema::CURRENT) }
        .to raise_error(ArgumentError, /run_id/)
    end

    it 'is idempotent when called twice with the same snapshot' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(backend.last_run_id).to eq(sample_snapshot.run_id)
    end
  end

  describe '#transactional_save' do
    it 'requires a block' do
      expect { backend.transactional_save }.to raise_error(ArgumentError, /block/)
    end

    it 'runs the block' do
      ran = false
      backend.transactional_save { ran = true }

      expect(ran).to be(true)
    end

    it 're-raises block exceptions' do
      expect { backend.transactional_save { raise 'boom' } }.to raise_error('boom')
    end

    it 'does not alter last_run_id when the block raises before save_graph completes' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      previous = backend.last_run_id
      begin
        backend.transactional_save { raise 'mid-save failure' }
      rescue StandardError
        # intentional
      end

      expect(backend.last_run_id).to eq(previous)
    end
  end

  describe '#clear!' do
    it 'removes every cache artifact' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      backend.clear!

      expect(backend.last_run_id).to be_nil
    end

    it 'is a no-op when nothing has been saved' do
      expect { backend.clear! }.not_to raise_error
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
