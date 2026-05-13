# frozen_string_literal: true

require 'tmpdir'
require 'rspec_tracer/storage/backend'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/sqlite_backend' if RUBY_ENGINE == 'ruby'

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe RSpecTracer::Storage::Backend do
  describe 'REQUIRED_METHODS' do
    it 'is frozen so callers cannot mutate the required-method list' do
      expect(described_class::REQUIRED_METHODS).to be_frozen
    end

    it 'lists exactly the five protocol methods (load/save/last_run_id/transactional/clear)' do
      expect(described_class::REQUIRED_METHODS)
        .to eq(%i[load_graph save_graph last_run_id transactional_save clear!])
    end
  end

  describe '.conforms?' do
    def conformant_stub
      Class.new do
        def load_graph(*); end
        def save_graph(*); end
        def last_run_id; end
        def transactional_save(*); end
        def clear!; end
      end.new
    end

    def partial_stub
      Class.new do
        def load_graph(*); end
        def last_run_id; end
        def transactional_save(*); end
        def clear!; end
      end.new
    end

    it 'is true for an object responding to every required method' do
      expect(described_class.conforms?(conformant_stub)).to be(true)
    end

    it 'is false when any method is missing' do
      expect(described_class.conforms?(partial_stub)).to be(false)
    end
  end

  # The factory is the single source of truth for json/sqlite dispatch
  # shared by Engine + CLI sub-commands (closes the gap that #183
  # surfaced — `cache:info` / `explain` couldn't compose with
  # `storage_backend :sqlite`). Coverage of the conditional + opt
  # threading + sqlite-gem-missing fallback path is split across the
  # describe blocks below.
  describe '.build' do
    let(:cache_path) { Dir.mktmpdir }
    let(:logger) { Class.new { def warn(*); end }.new }

    after { FileUtils.rm_rf(cache_path) }

    def build_config(backend:, opts: {})
      Struct.new(
        :storage_backend, :storage_backend_opts,
        :cache_retention_local_count, :cache_size_warn_per_file_mb, :cache_size_warn_total_mb,
        :logger, keyword_init: true
      ).new(
        storage_backend: backend, storage_backend_opts: opts,
        cache_retention_local_count: 5, cache_size_warn_per_file_mb: 10,
        cache_size_warn_total_mb: 50, logger: logger
      )
    end

    context 'when storage_backend is :json (default)' do
      it 'returns a JsonBackend instance' do
        backend = described_class.build(cache_path: cache_path, configuration: build_config(backend: :json))

        expect(backend).to be_a(RSpecTracer::Storage::JsonBackend)
      end

      it 'conforms to the protocol so callers can dispatch through last_run_id / load_graph' do
        backend = described_class.build(cache_path: cache_path, configuration: build_config(backend: :json))

        expect(described_class.conforms?(backend)).to be(true)
      end

      it 'selects the :json serializer when storage_backend_opts is empty' do
        backend = described_class.build(cache_path: cache_path, configuration: build_config(backend: :json))

        expect(backend.serializer).to eq(RSpecTracer::Storage::Serializer::Json)
      end

      it 'selects the :msgpack serializer when configured via storage_backend_opts' do
        skip 'msgpack gem unavailable' unless RSpecTracer::Storage::Serializer::Msgpack.available?
        config = build_config(backend: :json, opts: { serializer: :msgpack })

        backend = described_class.build(cache_path: cache_path, configuration: config)

        expect(backend.serializer).to eq(RSpecTracer::Storage::Serializer::Msgpack)
      end
    end

    context 'when storage_backend is :sqlite', :sqlite do
      before { skip 'sqlite backend unavailable on this Ruby' unless sqlite_available? }

      it 'returns a SqliteBackend instance' do
        backend = described_class.build(cache_path: cache_path, configuration: build_config(backend: :sqlite))

        expect(backend).to be_a(RSpecTracer::Storage::SqliteBackend)
      end

      it 'falls back to JsonBackend with a warn when SqliteBackend raises SqliteBackendError' do
        allow(RSpecTracer::Storage::SqliteBackend)
          .to receive(:new)
          .and_raise(RSpecTracer::Storage::SqliteBackend::SqliteBackendError, 'simulated missing gem')
        config = build_config(backend: :sqlite)
        allow(config.logger).to receive(:warn)

        backend = described_class.build(cache_path: cache_path, configuration: config)

        expect(backend).to be_a(RSpecTracer::Storage::JsonBackend)
        expect(config.logger)
          .to have_received(:warn).with(/sqlite backend unavailable.*simulated missing gem/)
      end

      def sqlite_available?
        return false unless RUBY_ENGINE == 'ruby'

        require 'sqlite3'
        true
      rescue LoadError
        false
      end
    end

    context 'when storage_backend is an unknown symbol' do
      it 'falls through to the :json branch (default behavior for unknown symbols)' do
        backend = described_class.build(cache_path: cache_path, configuration: build_config(backend: :unknown))

        expect(backend).to be_a(RSpecTracer::Storage::JsonBackend)
      end
    end

    it 'defaults the configuration parameter to RSpecTracer when omitted' do
      allow(RSpecTracer).to receive_messages(
        storage_backend: :json, storage_backend_opts: {},
        cache_retention_local_count: nil, cache_size_warn_per_file_mb: nil,
        cache_size_warn_total_mb: nil, logger: logger
      )

      backend = described_class.build(cache_path: cache_path)

      expect(backend).to be_a(RSpecTracer::Storage::JsonBackend)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
