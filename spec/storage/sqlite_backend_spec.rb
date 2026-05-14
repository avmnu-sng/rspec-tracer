# frozen_string_literal: true

require 'fileutils'
require 'set'
require 'tmpdir'
require 'rspec_tracer/storage/snapshot'

require_relative '../contracts/storage_backend'

# SqliteBackend is MRI-only (sqlite3 gem targets MRI's C API; JRuby
# uses a different driver entirely). Gemfile pins per-cell: ~> 2.0
# on Ruby >= 3.2, ~> 1.7 on Ruby 3.1. Skip when the gem can't be
# required so the JRuby matrix stays green.
return unless RUBY_ENGINE == 'ruby'

begin
  require 'sqlite3'
  require 'rspec_tracer/storage/sqlite_backend'
rescue LoadError
  return
end

# rubocop:disable RSpec/ExampleLength
RSpec.describe RSpecTracer::Storage::SqliteBackend do
  let(:tmp_base) { Dir.mktmpdir }
  let(:cache_path) { File.join(tmp_base, 'cache') }

  let(:backend) { described_class.new(cache_path: cache_path) }
  let(:other_backend) { described_class.new(cache_path: cache_path) }
  let(:sample_snapshot) { build_sample_snapshot('run-sqlite-abc') }

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  # Integer line keys match real engine output (record_coverage_delta
  # stores `file_entry[i] = delta`, Integer => Integer). Sqlite's
  # line_key column is INTEGER, so load reconstructs Integer => Integer.
  # JsonBackend round-trips through JSON which stringifies keys; the
  # two backends' round-trip shape differs on this one field, which is
  # why the contract spec's equality check uses PER-BACKEND sample data.
  def build_sample_snapshot(run_id)
    RSpecTracer::Storage::Snapshot.new(
      schema_version: RSpecTracer::Storage::Schema::CURRENT,
      run_id: run_id,
      all_examples: { 'ex1' => { id: 'ex1', description: 'desc' } },
      duplicate_examples: { 'ex1' => [{ id: 'ex1', file: 'a.rb' }] },
      interrupted_examples: Set.new(%w[ex2 ex3]),
      flaky_examples: Set.new(['ex4']),
      failed_examples: Set.new(['ex5']),
      pending_examples: Set.new(['ex6']),
      skipped_examples: Set.new(['ex7']),
      all_files: { '/a.rb' => { file_name: '/a.rb', file_path: '/tmp/a.rb', digest: 'abc' } },
      dependency: { 'ex1' => Set.new(['/a.rb', '/b.rb']) },
      reverse_dependency: { '/a.rb' => Set.new(['ex1']), '/b.rb' => Set.new(['ex1']) },
      examples_coverage: { 'ex1' => { '/a.rb' => { 0 => 1, 2 => 2 } } },
      boot_set: { 'lib/boot.rb' => 'deadbeef', 'spec/spec_helper.rb' => 'cafef00d' },
      wsi_snapshot: { 'Gemfile.lock' => 'feedc0de' },
      env_snapshot: { 'API_KEY' => 'facade1' },
      env_dependency: { 'ex1' => ['API_KEY'] }
    )
  end

  # Contract helper. Overwriting meta with garbage bytes forces
  # load_graph into the outer rescue, which returns nil per the
  # graceful-degradation contract.
  def corrupt_backend_storage!
    backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
    db_path = File.join(cache_path, RSpecTracer::Storage::SqliteBackend::DB_FILENAME)
    File.binwrite(db_path, "\x00\xFF not a sqlite db\xC2\x00")
  end

  it_behaves_like 'a Storage::Backend'

  describe 'on-disk layout' do
    before { backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT) }

    it 'creates a single sqlite3 file under cache_path' do
      expect(File.file?(File.join(cache_path, 'rspec_tracer.sqlite3'))).to be(true)
    end

    it 'does not leak WAL or SHM sidecars (journal_mode=MEMORY)' do
      expect(Dir[File.join(cache_path, '*.sqlite3-*')]).to be_empty
    end

    it 'creates every schema table' do
      db = SQLite3::Database.new(File.join(cache_path, 'rspec_tracer.sqlite3'))
      names = db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").map(&:first)

      expect(names).to include(
        'meta', 'examples', 'duplicate_examples', 'all_files',
        'dependency', 'examples_coverage', 'env_dependency',
        'digest_maps', 'id_sets'
      )
    ensure
      db&.close
    end

    it 'creates the dependency(file_name) index' do
      db = SQLite3::Database.new(File.join(cache_path, 'rspec_tracer.sqlite3'))
      indexes = db.execute(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'dependency'"
      ).map(&:first)

      expect(indexes).to include('idx_dependency_file_name')
    ensure
      db&.close
    end
  end

  describe 'lazy loading' do
    it 'returns a LazySnapshot from load_graph' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)

      loaded = other_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(loaded).to be_a(RSpecTracer::Storage::LazySnapshot)
    end

    it 'does not query a field until it is accessed' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      loaded = other_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)
      allow(other_backend).to receive(:read_field).and_call_original

      loaded.schema_version
      loaded.run_id

      expect(other_backend).not_to have_received(:read_field)
    end

    it 'reads only the touched field' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      loaded = other_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)
      allow(other_backend).to receive(:read_field).and_call_original

      loaded.dependency

      expect(other_backend).to have_received(:read_field).with(:dependency).once
    end
  end

  describe '#read_field' do
    before { backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT) }

    it 'raises ArgumentError on an unknown field' do
      expect { backend.read_field(:not_a_field) }
        .to raise_error(ArgumentError, /unknown snapshot field/)
    end

    it 'returns a Set for id-set fields' do
      expect(backend.read_field(:interrupted_examples)).to be_a(Set)
    end

    it 'returns Hash[id => Set] for dependency' do
      value = backend.read_field(:dependency)

      expect(value['ex1']).to be_a(Set)
    end

    it 'returns Hash[file_name => Set<id>] for reverse_dependency from the same table' do
      value = backend.read_field(:reverse_dependency)

      expect(value['/a.rb']).to eq(Set.new(['ex1']))
    end

    it 'returns Hash[id => Hash[path => Hash[Integer => Integer]]] for examples_coverage' do
      expect(backend.read_field(:examples_coverage))
        .to eq('ex1' => { '/a.rb' => { 0 => 1, 2 => 2 } })
    end

    it 'returns an empty Hash for the JSON-backend-only cache_hit_reason field' do
      expect(backend.read_field(:cache_hit_reason)).to eq({})
    end

    it 'returns an empty Hash for the JSON-backend-only filtered_examples field' do
      expect(backend.read_field(:filtered_examples)).to eq({})
    end
  end

  describe 'save is full-replace per run' do
    it 'drops rows from the prior run when saving a new snapshot' do
      first = build_sample_snapshot('run-first')
      first.all_examples = { 'first_only' => { id: 'first_only' } }
      second = build_sample_snapshot('run-second')
      second.all_examples = { 'second_only' => { id: 'second_only' } }

      backend.save_graph(first, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      backend.save_graph(second, schema_version: RSpecTracer::Storage::Schema::CURRENT)

      loaded = other_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)
      expect(loaded.all_examples.keys).to contain_exactly('second_only')
    end

    it 'leaves last_run_id at the prior run when the transaction raises mid-save' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      previous = backend.last_run_id
      allow(backend).to receive(:insert_examples).and_raise('mid-save failure')

      begin
        backend.save_graph(build_sample_snapshot('run-xyz'),
                           schema_version: RSpecTracer::Storage::Schema::CURRENT)
      rescue StandardError
        # intentional
      end

      expect(backend.last_run_id).to eq(previous)
    end
  end

  describe 'missing sqlite3 gem' do
    # Intercepting `require 'sqlite3'` inside the backend constructor
    # is the only way to exercise the LoadError path when sqlite3 is
    # already loaded in this test process. allow_any_instance_of is
    # the least-bad vehicle here; the alternative (subprocess with a
    # munged LOAD_PATH) is heavier + slower for one assertion.
    it 'raises SqliteBackendError at construct time' do
      allow_any_instance_of(described_class) # rubocop:disable RSpec/AnyInstance
        .to receive(:require).with('sqlite3').and_raise(LoadError)

      expect { described_class.new(cache_path: cache_path) }
        .to raise_error(described_class::SqliteBackendError, /sqlite3 gem is not installed/)
    end
  end
end
# rubocop:enable RSpec/ExampleLength
