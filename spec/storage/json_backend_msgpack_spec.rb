# frozen_string_literal: true

require 'fileutils'
require 'set'
require 'tmpdir'
require 'zlib'
require 'rspec_tracer/storage/json_backend'

require_relative '../contracts/storage_backend'

# JsonBackend with `serializer: :msgpack` must satisfy the same
# Storage::Backend contract as the default :json variant. Beyond the
# shared behavior, this spec asserts the msgpack-specific wire shape:
# files land under `.msgpack.gz` extensions, bytes inflate through
# zlib, and the fallback path fires cleanly when the gem is absent.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
RSpec.describe RSpecTracer::Storage::JsonBackend do
  context 'with serializer: :msgpack' do
    let(:tmp_base) { Dir.mktmpdir }
    let(:cache_path) { File.join(tmp_base, 'cache') }

    let(:backend) { described_class.new(cache_path: cache_path, serializer: :msgpack) }
    let(:other_backend) { described_class.new(cache_path: cache_path, serializer: :msgpack) }
    let(:sample_snapshot) { build_sample_snapshot('run-msgpack-abc') }

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
        boot_set: { 'lib/boot.rb' => 'deadbeef' },
        wsi_snapshot: { 'Gemfile.lock' => 'feedc0de' },
        env_snapshot: { 'API_KEY' => 'facade1' },
        env_dependency: { 'ex1' => ['API_KEY'] }
      )
    end

    # Contract helper: corrupt last_run.json so the shared example's
    # "does not raise on garbled bytes" assertion has something to
    # drive. last_run.json is always plain JSON regardless of the
    # per-field serializer, so the same bytes work for both variants.
    def corrupt_backend_storage!
      backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT)
      last_run = File.join(cache_path, described_class::LAST_RUN_FILENAME)
      File.binwrite(last_run, "\x00\xFF not json \xC2\x00")
    end

    it_behaves_like 'a Storage::Backend'

    describe 'on-disk layout' do
      before { backend.save_graph(sample_snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT) }

      it 'writes per-field files with .msgpack.gz extension' do
        run_dir = File.join(cache_path, sample_snapshot.run_id)

        expect(File.file?(File.join(run_dir, 'all_examples.msgpack.gz'))).to be(true)
      end

      it 'writes every field with .msgpack.gz extension (no leftover .json)' do
        run_dir = File.join(cache_path, sample_snapshot.run_id)

        expect(Dir[File.join(run_dir, '*.json')]).to be_empty
      end

      it 'keeps last_run.json as plain JSON (always human-debuggable)' do
        manifest_path = File.join(cache_path, described_class::LAST_RUN_FILENAME)

        expect(JSON.parse(File.read(manifest_path))['schema_version'])
          .to eq(RSpecTracer::Storage::Schema::CURRENT)
      end

      it 'produces zlib-compressed msgpack bytes on disk (inflates cleanly)' do
        path = File.join(cache_path, sample_snapshot.run_id, 'boot_set.msgpack.gz')
        raw = File.binread(path)
        inflated = Zlib::Inflate.inflate(raw)

        expect(MessagePack.unpack(inflated)).to eq('lib/boot.rb' => 'deadbeef')
      end
    end

    describe 'Time + Symbol round-trip via Snapshot (regression for #182)' do
      # Inner Hash keys are Symbols (Ruby `key:` shorthand), matching
      # how RSpec example metadata gets populated on the in-memory
      # snapshot. The Symbol type extension preserves both keys and
      # values across the cache boundary.
      it 'round-trips a Snapshot containing Time values losslessly' do
        snap_with_time = build_sample_snapshot('run-time')
        snap_with_time.all_examples = {
          'ex1' => {
            id: 'ex1',
            description: 'desc',
            recorded_at: Time.utc(2026, 5, 13, 12, 0, 0)
          }
        }
        backend.save_graph(snap_with_time, schema_version: RSpecTracer::Storage::Schema::CURRENT)

        loaded = other_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

        expect(loaded.all_examples['ex1'][:recorded_at]).to eq(Time.utc(2026, 5, 13, 12, 0, 0))
      end

      it 'round-trips a Snapshot containing Symbol values losslessly' do
        snap_with_symbols = build_sample_snapshot('run-sym')
        snap_with_symbols.all_examples = {
          'ex1' => { id: 'ex1', status: :flaky, tags: %i[slow integration] }
        }
        backend.save_graph(snap_with_symbols, schema_version: RSpecTracer::Storage::Schema::CURRENT)

        loaded = other_backend.load_graph(schema_version: RSpecTracer::Storage::Schema::CURRENT)

        expect(loaded.all_examples['ex1'][:status]).to eq(:flaky)
        expect(loaded.all_examples['ex1'][:tags]).to eq(%i[slow integration])
      end
    end

    describe 'disk size reduction' do
      it 'is noticeably smaller than the :json equivalent on a path-repetitive cache' do
        fat_snap = build_sample_snapshot('run-fat')
        fat_snap.dependency = (1..500).to_h do |i|
          ["ex#{i}", Set.new(['/very/long/path/that/repeats.rb', '/another/repeated/path.rb'])]
        end

        json_cache = File.join(tmp_base, 'json_cache')
        msgpack_cache = File.join(tmp_base, 'msgpack_cache')
        described_class.new(cache_path: json_cache, serializer: :json)
          .save_graph(fat_snap, schema_version: RSpecTracer::Storage::Schema::CURRENT)
        described_class.new(cache_path: msgpack_cache, serializer: :msgpack)
          .save_graph(fat_snap, schema_version: RSpecTracer::Storage::Schema::CURRENT)

        json_size = Dir[File.join(json_cache, '**', '*.json')].sum { |f| File.size(f) }
        mp_size = Dir[File.join(msgpack_cache, '**', '*.msgpack.gz')].sum { |f| File.size(f) }

        # Plan AC: on-disk size for msgpack variant < 0.5x the JSON size
        # on representative path-repetitive content.
        expect(mp_size).to be < (json_size * 0.5)
      end
    end

    describe 'missing msgpack gem fallback' do
      let(:logger) { instance_double(RSpecTracer::Logger, warn: nil) }

      it 'warns and falls back to :json when the msgpack gem is missing' do
        allow(RSpecTracer::Storage::Serializer::Msgpack).to receive(:available?).and_return(false)

        b = described_class.new(cache_path: cache_path, serializer: :msgpack, logger: logger)

        expect(b.serializer).to eq(RSpecTracer::Storage::Serializer::Json)
        expect(logger).to have_received(:warn).with(/msgpack gem is not installed/)
      end
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
