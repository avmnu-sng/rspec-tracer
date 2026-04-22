# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'
require 'tmpdir'
require 'rspec_tracer/storage/json_backend'

require_relative '../contracts/storage_backend'

RSpec.describe RSpecTracer::Storage::JsonBackend do
  let(:tmp_base) { Dir.mktmpdir }
  let(:cache_path) { File.join(tmp_base, 'cache') }

  let(:backend) { described_class.new(cache_path: cache_path) }
  let(:other_backend) { described_class.new(cache_path: cache_path) }
  let(:sample_snapshot) { build_sample_snapshot('run-abc') }

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

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
      all_files: { '/a.rb' => { file_name: 'a.rb', digest: 'abc' } },
      dependency: { 'ex1' => Set.new(['/a.rb', '/b.rb']) },
      reverse_dependency: { '/a.rb' => Set.new(['ex1']) },
      examples_coverage: { 'ex1' => { '/a.rb' => [1, nil, 2] } },
      boot_set: { 'lib/boot.rb' => 'deadbeef', 'spec/spec_helper.rb' => 'cafef00d' },
      wsi_snapshot: { 'Gemfile.lock' => 'feedc0de', '.ruby-version' => 'b16b00b5' },
      env_snapshot: { 'API_KEY' => 'facade1', 'ROLE_CONFIG' => 'baadf00d' },
      env_dependency: { 'ex1' => ['API_KEY'], 'ex2' => %w[ROLE_CONFIG API_KEY] }
    )
  end

  # Contract helper - deletes the cache so the "no raise on garbled
  # bytes" shared example has something to corrupt. See the JSON-
  # specific corruption tests below for the content-level assertions.
  def corrupt_backend_storage!
    backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
    last_run = File.join(cache_path, described_class::LAST_RUN_FILENAME)
    File.binwrite(last_run, "\x00\xFF not json \xC2\x00")
  end

  it_behaves_like 'a Storage::Backend'

  describe 'FILENAMES constant' do
    it 'is frozen' do
      expect(described_class::FILENAMES).to be_frozen
    end

    it 'lists exactly the 15 per-run files (boot_set+wsi+env_snapshot+env_dependency added in M3.7+M4.3+M5.2+M6.1)' do
      expect(described_class::FILENAMES).to eq(expected_filenames)
    end

    def expected_filenames
      %w[
        all_examples.json duplicate_examples.json
        interrupted_examples.json flaky_examples.json failed_examples.json
        pending_examples.json skipped_examples.json
        all_files.json dependency.json reverse_dependency.json examples_coverage.json
        boot_set.json wsi_snapshot.json env_snapshot.json env_dependency.json
      ]
    end
  end

  describe 'boot_set round-trip' do
    it 'persists and reloads a non-empty boot_set' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      loaded = other_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(loaded.boot_set).to eq(sample_snapshot.boot_set)
    end

    it 'writes boot_set.json with a plain Hash[relative_path => digest] body' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      path = File.join(cache_path, sample_snapshot.run_id, 'boot_set.json')

      expect(JSON.parse(File.read(path)))
        .to eq('lib/boot.rb' => 'deadbeef', 'spec/spec_helper.rb' => 'cafef00d')
    end

    it 'tolerates a malformed boot_set.json (returns {})' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      path = File.join(cache_path, sample_snapshot.run_id, 'boot_set.json')
      File.binwrite(path, "\x00 garbage".b)
      loaded = backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(loaded.boot_set).to eq({})
    end

    it 'coerces a non-Hash JSON body (e.g. array) to {}' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      path = File.join(cache_path, sample_snapshot.run_id, 'boot_set.json')
      File.write(path, JSON.dump(%w[not a hash]))
      loaded = backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(loaded.boot_set).to eq({})
    end
  end

  describe 'env_snapshot round-trip (M5.2)' do
    it 'persists and reloads a non-empty env_snapshot' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      loaded = other_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(loaded.env_snapshot).to eq(sample_snapshot.env_snapshot)
    end

    it 'writes env_snapshot.json with a plain Hash[env_name => digest] body' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      path = File.join(cache_path, sample_snapshot.run_id, 'env_snapshot.json')

      expect(JSON.parse(File.read(path)))
        .to eq('API_KEY' => 'facade1', 'ROLE_CONFIG' => 'baadf00d')
    end

    it 'tolerates a malformed env_snapshot.json (returns {})' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      path = File.join(cache_path, sample_snapshot.run_id, 'env_snapshot.json')
      File.binwrite(path, "\x00 garbage".b)
      loaded = backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(loaded.env_snapshot).to eq({})
    end

    it 'coerces a non-Hash JSON body (e.g. array) to {}' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      path = File.join(cache_path, sample_snapshot.run_id, 'env_snapshot.json')
      File.write(path, JSON.dump(%w[not a hash]))
      loaded = backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(loaded.env_snapshot).to eq({})
    end
  end

  describe 'env_dependency round-trip (M6.1)' do
    it 'persists and reloads a non-empty env_dependency' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      loaded = other_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(loaded.env_dependency).to eq(sample_snapshot.env_dependency)
    end

    it 'writes env_dependency.json with Hash[example_id => Array<env_name>] body' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      path = File.join(cache_path, sample_snapshot.run_id, 'env_dependency.json')

      expect(JSON.parse(File.read(path)))
        .to eq('ex1' => ['API_KEY'], 'ex2' => %w[ROLE_CONFIG API_KEY])
    end

    it 'tolerates a malformed env_dependency.json (returns {})' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      path = File.join(cache_path, sample_snapshot.run_id, 'env_dependency.json')
      File.binwrite(path, "\x00 garbage".b)
      loaded = backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(loaded.env_dependency).to eq({})
    end

    it 'coerces a non-Hash JSON body to {}' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      path = File.join(cache_path, sample_snapshot.run_id, 'env_dependency.json')
      File.write(path, JSON.dump(%w[not a hash]))
      loaded = backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(loaded.env_dependency).to eq({})
    end

    it 'survives a pre-M6.1 cache (missing env_dependency.json) without a cold re-run signal' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      File.delete(File.join(cache_path, sample_snapshot.run_id, 'env_dependency.json'))
      loaded = other_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(loaded.env_dependency).to eq({})
    end
  end

  describe '#save_graph on-disk layout' do
    before { backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT) }

    it 'writes every FILENAMES entry under the run-id directory' do
      run_dir = File.join(cache_path, sample_snapshot.run_id)
      described_class::FILENAMES.each { |name| expect(File.file?(File.join(run_dir, name))).to be(true) }
    end

    it 'writes last_run.json at cache_path (sibling of the run-id dir)' do
      expect(File.file?(File.join(cache_path, described_class::LAST_RUN_FILENAME))).to be(true)
    end

    it 'stamps last_run.json with schema_version' do
      manifest = JSON.parse(File.read(File.join(cache_path, described_class::LAST_RUN_FILENAME)))

      expect(manifest['schema_version']).to eq(RSpecTracer::Storage::Schema::CURRENT)
    end

    it 'stamps last_run.json with run_id' do
      manifest = JSON.parse(File.read(File.join(cache_path, described_class::LAST_RUN_FILENAME)))

      expect(manifest['run_id']).to eq(sample_snapshot.run_id)
    end

    it 'stamps last_run.json with a UTC ISO-8601 timestamp' do
      manifest = JSON.parse(File.read(File.join(cache_path, described_class::LAST_RUN_FILENAME)))

      expect(manifest['timestamp']).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    end

    it 'stores interrupted_examples sorted as an Array on disk' do
      path = File.join(cache_path, sample_snapshot.run_id, 'interrupted_examples.json')

      expect(JSON.parse(File.read(path))).to eq(%w[ex2 ex3])
    end

    it 'stores dependency with Array values on disk (Set on load)' do
      path = File.join(cache_path, sample_snapshot.run_id, 'dependency.json')

      expect(JSON.parse(File.read(path))).to eq('ex1' => %w[/a.rb /b.rb])
    end
  end

  describe 'UTF-8 encoding (regression for M3.1 Encoding::InvalidByteSequenceError)' do
    it 'round-trips example titles containing non-ASCII bytes' do
      snap = build_sample_snapshot('run-utf8')
      snap.all_examples = { 'ex-utf8' => { id: 'ex-utf8', description: "naïve café – \u{1F600}" } }
      backend.save_graph(snap, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      loaded = other_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(loaded.all_examples['ex-utf8'][:description]).to eq("naïve café – \u{1F600}")
    end
  end

  describe 'schema-mismatch logging' do
    def prime_with_bad_schema_version(backend_for_save)
      backend_for_save.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      path = File.join(cache_path, described_class::LAST_RUN_FILENAME)
      manifest = JSON.parse(File.read(path))
      manifest['schema_version'] = 1
      File.write(path, JSON.pretty_generate(manifest))
    end

    it 'returns nil when stored schema is unsupported' do
      logger = instance_double(RSpecTracer::Logger, info: nil)
      logging_backend = described_class.new(cache_path: cache_path, logger: logger)
      prime_with_bad_schema_version(logging_backend)

      expect(logging_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)).to be_nil
    end

    it 'emits an info log line on mismatch' do
      logger = instance_double(RSpecTracer::Logger, info: nil)
      logging_backend = described_class.new(cache_path: cache_path, logger: logger)
      prime_with_bad_schema_version(logging_backend)
      logging_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(logger).to have_received(:info).with(/schema_version mismatch/)
    end
  end

  describe 'corruption tolerance' do
    it 'returns nil when last_run.json is binary garbage' do
      FileUtils.mkdir_p(cache_path)
      File.binwrite(File.join(cache_path, described_class::LAST_RUN_FILENAME), "\x00\xFF not json".b)

      expect(backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)).to be_nil
    end

    it 'returns nil when last_run.json parses but is not a Hash' do
      FileUtils.mkdir_p(cache_path)
      File.write(File.join(cache_path, described_class::LAST_RUN_FILENAME), JSON.dump([1, 2, 3]))

      expect(backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)).to be_nil
    end

    it 'returns nil when the run-id directory vanished after last_run.json was written' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      FileUtils.rm_rf(File.join(cache_path, sample_snapshot.run_id))

      expect(backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)).to be_nil
    end

    it 'returns nil when the run_id field in last_run.json is missing' do
      FileUtils.mkdir_p(cache_path)
      File.write(File.join(cache_path, described_class::LAST_RUN_FILENAME),
                 JSON.dump('schema_version' => RSpecTracer::Storage::Schema::CURRENT))

      expect(backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)).to be_nil
    end

    it 'tolerates a per-run file being malformed (returns Snapshot with default for that field)' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      path = File.join(cache_path, sample_snapshot.run_id, 'dependency.json')
      File.binwrite(path, "\x00 garbage".b)
      loaded = backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(loaded.dependency).to eq({})
    end
  end

  describe 'atomic last_run.json write' do
    it 'does not leave a .tmp file behind after a successful save' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)

      expect(Dir.glob(File.join(cache_path, 'last_run.json.tmp.*'))).to be_empty
    end

    it 'cleans up .tmp files when a rename fails mid-save' do
      FileUtils.mkdir_p(cache_path)
      allow(File).to receive(:rename).and_raise(Errno::EACCES)
      ignore_raise { backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT) }

      expect(Dir.glob(File.join(cache_path, sample_snapshot.run_id, '*.tmp.*'))).to be_empty
    end
  end

  describe 'atomicity: partial write does not poison the cache' do
    def save_with_late_failure
      v1 = build_sample_snapshot('run-v1')
      v2 = build_sample_snapshot('run-v2')
      backend.save_graph(v1, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      allow(File).to receive(:rename).and_wrap_original do |meth, src, dst|
        raise Errno::EACCES if dst.end_with?('examples_coverage.json')

        meth.call(src, dst)
      end
      ignore_raise { backend.save_graph(v2, schema_version: RSpecTracer::Storage::Schema::CURRENT) }
    end

    it 'leaves the previous last_run_id intact when a per-run write fails mid-transaction' do
      save_with_late_failure

      expect(backend.last_run_id).to eq('run-v1')
    end
  end

  describe '#clear!' do
    it 'removes the cache_path directory entirely' do
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      backend.clear!

      expect(File.directory?(cache_path)).to be(false)
    end
  end

  describe 'concurrency - flock serializes writers' do
    def second_flock_under_transactional_save
      FileUtils.mkdir_p(cache_path)
      lock = File.join(cache_path, described_class::LOCK_FILENAME)
      result = nil
      backend.transactional_save { result = File.open(lock, File::RDWR | File::CREAT) { |f| f.flock(File::LOCK_EX | File::LOCK_NB) } }
      result
    end

    it 'holds an exclusive lock during transactional_save' do
      expect(second_flock_under_transactional_save).to be(false)
    end
  end

  def ignore_raise
    yield
  rescue StandardError
    nil
  end

  # rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/MultipleExpectations, RSpec/ExampleLength
  describe '#merge_from_peers' do
    let(:top_cache)     { File.join(tmp_base, 'top') }
    let(:peer_one_path) { File.join(tmp_base, 'top', 'parallel_tests_1') }
    let(:peer_two_path) { File.join(tmp_base, 'top', 'parallel_tests_2') }
    let(:top_backend)   { described_class.new(cache_path: top_cache) }

    def write_peer(path, snapshot)
      FileUtils.mkdir_p(path)
      described_class.new(cache_path: path).save_graph(
        snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT
      )
    end

    def peer_snapshot(run_id, example_id, file_name, digest)
      RSpecTracer::Storage::Snapshot.new(
        schema_version: RSpecTracer::Storage::Schema::CURRENT,
        run_id: run_id,
        all_examples: { example_id => { id: example_id, description: "ex #{example_id}" } },
        duplicate_examples: {},
        interrupted_examples: Set.new,
        flaky_examples: Set.new,
        failed_examples: Set.new([example_id]),
        pending_examples: Set.new,
        skipped_examples: Set.new,
        all_files: { file_name => { file_name: file_name, digest: digest } },
        dependency: { example_id => Set.new([file_name]) },
        reverse_dependency: { file_name => Set.new([example_id]) },
        examples_coverage: { example_id => { file_name => { '0' => 1, '2' => 3 } } },
        boot_set: { "lib/#{example_id}_boot.rb" => "boot#{example_id}" },
        wsi_snapshot: { 'Gemfile.lock' => "wsi-#{run_id}" },
        env_snapshot: { "ENV_#{example_id.upcase}" => "env-#{run_id}" },
        env_dependency: { example_id => ["ENV_#{example_id.upcase}"] }
      )
    end

    it 'returns nil when no peer directories exist' do
      expect(top_backend.merge_from_peers([], schema_version: RSpecTracer::Storage::Schema::CURRENT)).to be_nil
    end

    it 'returns nil when every peer path is missing / empty' do
      result = top_backend.merge_from_peers(
        [peer_one_path, peer_two_path],
        schema_version: RSpecTracer::Storage::Schema::CURRENT
      )
      expect(result).to be_nil
    end

    it 'unions all_examples, all_files, dependency, boot_set, wsi, env across peers' do
      write_peer(peer_one_path, peer_snapshot('p1', 'ex1', '/lib/a.rb', 'digest-a'))
      write_peer(peer_two_path, peer_snapshot('p2', 'ex2', '/lib/b.rb', 'digest-b'))

      merged = top_backend.merge_from_peers(
        [peer_one_path, peer_two_path],
        schema_version: RSpecTracer::Storage::Schema::CURRENT
      )

      expect(merged.all_examples.keys).to contain_exactly('ex1', 'ex2')
      expect(merged.all_files.keys).to contain_exactly('/lib/a.rb', '/lib/b.rb')
      expect(merged.dependency['ex1']).to include('/lib/a.rb')
      expect(merged.dependency['ex2']).to include('/lib/b.rb')
      expect(merged.boot_set.keys).to include('lib/ex1_boot.rb', 'lib/ex2_boot.rb')
      expect(merged.wsi_snapshot['Gemfile.lock']).to be_a(String)
      expect(merged.env_snapshot.keys).to include('ENV_EX1', 'ENV_EX2')
    end

    it 'unions env_dependency entries per-example across peers (M6.1)' do
      write_peer(peer_one_path, peer_snapshot('p1', 'ex1', '/lib/a.rb', 'digest-a'))
      write_peer(peer_two_path, peer_snapshot('p2', 'ex2', '/lib/b.rb', 'digest-b'))

      merged = top_backend.merge_from_peers(
        [peer_one_path, peer_two_path],
        schema_version: RSpecTracer::Storage::Schema::CURRENT
      )

      expect(merged.env_dependency).to include(
        'ex1' => ['ENV_EX1'],
        'ex2' => ['ENV_EX2']
      )
    end

    it 'unions overlapping env_dependency arrays set-wise' do
      shared_one = peer_snapshot('p1', 'ex1', '/lib/a.rb', 'da')
      shared_two = peer_snapshot('p2', 'ex1', '/lib/a.rb', 'da')
      shared_two.env_dependency = { 'ex1' => %w[ENV_EX1 ENV_EXTRA] }

      write_peer(peer_one_path, shared_one)
      write_peer(peer_two_path, shared_two)

      merged = top_backend.merge_from_peers(
        [peer_one_path, peer_two_path],
        schema_version: RSpecTracer::Storage::Schema::CURRENT
      )

      expect(merged.env_dependency['ex1']).to match_array(%w[ENV_EX1 ENV_EXTRA])
    end

    it 'unions example-status ID sets' do
      write_peer(peer_one_path, peer_snapshot('p1', 'ex1', '/a.rb', 'da'))
      write_peer(peer_two_path, peer_snapshot('p2', 'ex2', '/b.rb', 'db'))

      merged = top_backend.merge_from_peers(
        [peer_one_path, peer_two_path],
        schema_version: RSpecTracer::Storage::Schema::CURRENT
      )

      expect(merged.failed_examples).to eq(Set.new(%w[ex1 ex2]))
    end

    it 'recomputes reverse_dependency from the unioned dependency map' do
      write_peer(peer_one_path, peer_snapshot('p1', 'ex1', '/a.rb', 'da'))
      write_peer(peer_two_path, peer_snapshot('p2', 'ex2', '/b.rb', 'db'))

      merged = top_backend.merge_from_peers(
        [peer_one_path, peer_two_path],
        schema_version: RSpecTracer::Storage::Schema::CURRENT
      )

      expect(merged.reverse_dependency['/a.rb']).to include('ex1')
      expect(merged.reverse_dependency['/b.rb']).to include('ex2')
    end

    it 'sums per-line coverage strengths across peers when they overlap' do
      shared = peer_snapshot('p1', 'ex1', '/lib/shared.rb', 'dig')
      other = peer_snapshot('p2', 'ex1', '/lib/shared.rb', 'dig')

      write_peer(peer_one_path, shared)
      write_peer(peer_two_path, other)

      merged = top_backend.merge_from_peers(
        [peer_one_path, peer_two_path],
        schema_version: RSpecTracer::Storage::Schema::CURRENT
      )

      expect(merged.examples_coverage['ex1']['/lib/shared.rb']).to eq('0' => 2, '2' => 6)
    end

    it 'persists the merged snapshot under the top-level cache path' do
      write_peer(peer_one_path, peer_snapshot('p1', 'ex1', '/a.rb', 'da'))
      write_peer(peer_two_path, peer_snapshot('p2', 'ex2', '/b.rb', 'db'))

      top_backend.merge_from_peers(
        [peer_one_path, peer_two_path],
        schema_version: RSpecTracer::Storage::Schema::CURRENT
      )

      reloaded = described_class.new(cache_path: top_cache)
        .load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)
      expect(reloaded.all_examples.keys).to contain_exactly('ex1', 'ex2')
    end

    it 'derives run_id from the merged example id list (hex MD5)' do
      write_peer(peer_one_path, peer_snapshot('p1', 'ex1', '/a.rb', 'da'))
      write_peer(peer_two_path, peer_snapshot('p2', 'ex2', '/b.rb', 'db'))

      merged = top_backend.merge_from_peers(
        [peer_one_path, peer_two_path],
        schema_version: RSpecTracer::Storage::Schema::CURRENT
      )

      expect(merged.run_id).to match(/\A[0-9a-f]{32}\z/)
    end
  end
  # rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/MultipleExpectations, RSpec/ExampleLength

  # rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/MultipleExpectations
  describe RSpecTracer::Storage::JsonBackend::Merger do
    let(:schema) { RSpecTracer::Storage::Schema::CURRENT }

    def make_snapshot(overrides = {})
      base = {
        schema_version: schema, run_id: 'r',
        all_examples: {}, duplicate_examples: {},
        interrupted_examples: Set.new, flaky_examples: Set.new,
        failed_examples: Set.new, pending_examples: Set.new,
        skipped_examples: Set.new,
        all_files: {}, dependency: {}, reverse_dependency: {},
        examples_coverage: {},
        boot_set: {}, wsi_snapshot: {}
      }
      RSpecTracer::Storage::Snapshot.new(**base, **overrides)
    end

    it 'treats nil fields as empty collections (graceful under partial peers)' do
      s1 = make_snapshot(all_examples: nil, dependency: nil, examples_coverage: nil)

      merged = described_class.call([s1], schema_version: schema)

      expect(merged.all_examples).to eq({})
      expect(merged.dependency).to eq({})
    end

    it 'concatenates duplicate_examples entries across peers' do
      s1 = make_snapshot(duplicate_examples: { 'ex' => [{ a: 1 }] })
      s2 = make_snapshot(duplicate_examples: { 'ex' => [{ a: 2 }] })

      merged = described_class.call([s1, s2], schema_version: schema)

      expect(merged.duplicate_examples['ex']).to eq([{ a: 1 }, { a: 2 }])
    end
  end
  # rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/MultipleExpectations
end
