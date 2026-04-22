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
      wsi_snapshot: { 'Gemfile.lock' => 'feedc0de', '.ruby-version' => 'b16b00b5' }
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

    it 'lists exactly the 13 per-run files (M3.7 added boot_set.json; M4.3 added wsi_snapshot.json)' do
      expect(described_class::FILENAMES).to eq(expected_filenames)
    end

    def expected_filenames
      %w[
        all_examples.json duplicate_examples.json
        interrupted_examples.json flaky_examples.json failed_examples.json
        pending_examples.json skipped_examples.json
        all_files.json dependency.json reverse_dependency.json examples_coverage.json
        boot_set.json wsi_snapshot.json
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
end
