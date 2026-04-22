# frozen_string_literal: true

require 'securerandom'

RSpec.describe RSpecTracer::Configuration do
  subject(:config) { clazz.new }

  let(:clazz) { Class.new { include RSpecTracer::Configuration } }

  describe '#configure DSL wrapper' do
    # The DSL wrapper aliases every private setter to `_name`, then
    # redefines the public name as a thin forwarder. Before M4.1 the
    # forwarder stripped keyword arguments silently; M4.1 threads
    # `**kwargs` through so `track_rails_defaults except: [:views]`
    # (and the deferred M3.4/M3.8 `storage_backend` opts) work.
    it 'forwards keyword arguments through to the underlying setter' do
      params = described_class
        .instance_method(:track_rails_defaults)
        .parameters
        .map(&:first)

      expect(params).to include(:keyrest)
    end

    it 'still forwards positional arguments and blocks' do
      params = described_class
        .instance_method(:track_rails_defaults)
        .parameters
        .map(&:first)

      expect(params).to include(:rest, :block)
    end
  end

  describe '#root' do
    context 'when not configured' do
      it 'returns current working directory' do
        expect(config.root).to eq(Dir.getwd)
      end
    end

    context 'when configured' do
      let(:root) { '/tmp/rspec_tracer/root' }

      before { config.root(root) }

      it 'returns the provided directory' do
        expect(config.root).to eq(root)
      end

      context 'when configured again with nil' do
        before { config.root(nil) }

        it 'does not change the root' do
          expect(config.root).to eq(root)
        end
      end
    end
  end

  describe '#cache_path' do
    context 'without test suite id' do
      before { stub_const('ENV', ENV.to_hash.merge('TEST_SUITE_ID' => nil)) }

      it 'returns cache path without suite id' do
        expect(config.cache_path).to eq("#{Dir.getwd}/rspec_tracer_cache")
      end
    end

    context 'with test suite id' do
      let(:suite_id) { SecureRandom.random_number(1..10) }

      before { stub_const('ENV', ENV.to_hash.merge('TEST_SUITE_ID' => suite_id)) }

      it 'returns cache path with suite id' do
        expect(config.cache_path).to eq("#{Dir.getwd}/rspec_tracer_cache/#{suite_id}")
      end
    end
  end

  describe '#coverage_path' do
    context 'without test suite id' do
      before { stub_const('ENV', ENV.to_hash.merge('TEST_SUITE_ID' => nil)) }

      it 'returns coverage path without suite id' do
        expect(config.coverage_path).to eq("#{Dir.getwd}/rspec_tracer_coverage")
      end
    end

    context 'with test suite id' do
      let(:suite_id) { SecureRandom.random_number(1..10) }

      before { stub_const('ENV', ENV.to_hash.merge('TEST_SUITE_ID' => suite_id)) }

      it 'returns coverage path with suite id' do
        expect(config.coverage_path).to eq("#{Dir.getwd}/rspec_tracer_coverage/#{suite_id}")
      end
    end
  end

  describe '#coverage_tracked_files' do
    context 'when not configured' do
      it 'returns current nil' do
        expect(config.coverage_tracked_files).to be_nil
      end
    end

    context 'when configured' do
      let(:glob) { '{app,lib}/**/*.rb' }

      before { config.coverage_track_files(glob) }

      it 'returns the configured glob' do
        expect(config.coverage_tracked_files).to eq(glob)
      end

      context 'when configured again with nil' do
        before { config.coverage_track_files(nil) }

        it 'returns nil' do
          expect(config.coverage_tracked_files).to be_nil
        end
      end
    end
  end

  describe '#track_files' do
    it 'returns an empty list when never configured' do
      expect(config.declared_globs).to eq([])
    end

    it 'accumulates across multiple calls' do
      config.track_files('db/schema.rb')
      config.track_files('config/**/*.yml')

      expect(config.declared_globs).to eq(%w[db/schema.rb config/**/*.yml])
    end

    it 'accepts multiple globs per call' do
      config.track_files('a.rb', 'b.rb')

      expect(config.declared_globs).to eq(%w[a.rb b.rb])
    end

    it 'flattens nested arrays' do
      config.track_files(%w[a.rb b.rb])

      expect(config.declared_globs).to eq(%w[a.rb b.rb])
    end

    it 'de-duplicates repeated globs' do
      config.track_files('a.rb')
      config.track_files('a.rb')

      expect(config.declared_globs).to eq(['a.rb'])
    end

    it 'coerces non-string globs to strings' do
      config.track_files(Pathname.new('a.rb'))

      expect(config.declared_globs).to eq(['a.rb'])
    end

    it 'drops nil entries' do
      config.track_files(nil, 'a.rb', nil)

      expect(config.declared_globs).to eq(['a.rb'])
    end
  end

  describe '#declared_globs consolidation' do
    it 'returns a frozen array' do
      expect(config.declared_globs).to be_frozen
    end

    it 'includes the legacy coverage_track_files value' do
      config.coverage_track_files('app/**/*.rb')

      expect(config.declared_globs).to eq(['app/**/*.rb'])
    end

    it 'merges track_files and coverage_track_files (track_files first)' do
      config.track_files('db/schema.rb')
      config.coverage_track_files('app/**/*.rb')

      expect(config.declared_globs).to eq(%w[db/schema.rb app/**/*.rb])
    end

    it 'de-duplicates a glob declared via both surfaces' do
      config.track_files('app/**/*.rb')
      config.coverage_track_files('app/**/*.rb')

      expect(config.declared_globs).to eq(['app/**/*.rb'])
    end
  end

  describe '#freeze_declared_globs!' do
    it 'prevents subsequent track_files calls' do
      config.track_files('a.rb')
      config.freeze_declared_globs!

      expect { config.track_files('b.rb') }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /cannot be called/)
    end

    it 'keeps previously-declared globs readable after freezing' do
      config.track_files('a.rb')
      config.freeze_declared_globs!

      expect(config.declared_globs).to eq(['a.rb'])
    end
  end

  describe '#track_rails_defaults' do
    before { require 'rspec_tracer/rails/preset' }

    it 'accumulates the full Rails preset glob set into declared_globs' do
      config.track_rails_defaults

      expect(config.declared_globs).to include(*RSpecTracer::Rails::Preset.globs)
    end

    it 'honors the except: kwarg to skip a category' do
      config.track_rails_defaults(except: [:views])

      RSpecTracer::Rails::Preset::DEFAULTS[:views].each do |view_glob|
        expect(config.declared_globs).not_to include(view_glob)
      end
    end

    it 'keeps non-excluded categories when except: is used' do
      config.track_rails_defaults(except: [:views])

      expect(config.declared_globs).to include(*RSpecTracer::Rails::Preset::DEFAULTS[:locales])
    end

    it 'raises for an unknown except: key' do
      expect { config.track_rails_defaults(except: [:bogus]) }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /unknown track_rails_defaults/)
    end

    it 'is idempotent across repeat calls (de-duplicated via declared_globs)' do
      config.track_rails_defaults
      first = config.declared_globs.dup

      config.track_rails_defaults

      expect(config.declared_globs).to eq(first)
    end

    it 'composes with explicit track_files calls' do
      config.track_files('custom/**/*.rb')
      config.track_rails_defaults

      expect(config.declared_globs).to include('custom/**/*.rb', *RSpecTracer::Rails::Preset.globs)
    end
  end

  describe '#storage_backend' do
    it 'defaults to :json when never configured' do
      expect(config.storage_backend).to eq(:json)
    end

    it 'coerces a string argument to a symbol' do
      config.storage_backend('json')

      expect(config.storage_backend).to eq(:json)
    end

    it 'raises InvalidUsageError for an unknown backend name' do
      expect { config.storage_backend(:bogus) }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /unknown storage backend/)
    end

    it 'honors RSPEC_TRACER_STORAGE over the argument' do
      stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_STORAGE' => 'json'))

      expect(config.storage_backend(:json)).to eq(:json)
    end

    it 'still rejects an unknown backend when set via ENV' do
      stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_STORAGE' => 'bogus'))

      expect { config.storage_backend }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /unknown storage backend/)
    end

    it 'memoizes the resolved name across no-arg calls' do
      config.storage_backend(:json)
      first = config.storage_backend
      second = config.storage_backend

      expect([first, second]).to eq(%i[json json])
    end
  end

  describe '#use_v2_tracker' do
    it 'defaults to false when never configured' do
      expect(config.use_v2_tracker).to be(false)
    end

    it 'returns the last value set via the DSL' do
      config.use_v2_tracker(true)

      expect(config.use_v2_tracker).to be(true)
    end

    it 'coerces any non-true value to false' do
      config.use_v2_tracker('yes')

      expect(config.use_v2_tracker).to be(false)
    end

    it 'honors RSPEC_TRACER_USE_V2_TRACKER=true over the DSL' do
      stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_USE_V2_TRACKER' => 'true'))

      expect(config.use_v2_tracker(false)).to be(true)
    end

    it 'treats any non-"true" ENV value as false' do
      stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_USE_V2_TRACKER' => '1'))

      expect(config.use_v2_tracker(true)).to be(false)
    end

    it 'memoizes across no-arg reads' do
      config.use_v2_tracker(true)
      first = config.use_v2_tracker
      second = config.use_v2_tracker

      expect([first, second]).to eq([true, true])
    end

    it 'keeps the previous value when re-called with nil' do
      config.use_v2_tracker(true)
      config.use_v2_tracker(nil)

      expect(config.use_v2_tracker).to be(true)
    end
  end

  describe '#transitive_load_tracking' do
    it 'defaults to true when never configured' do
      expect(config.transitive_load_tracking).to be(true)
    end

    it 'returns the last value set via the DSL' do
      config.transitive_load_tracking(false)

      expect(config.transitive_load_tracking).to be(false)
    end

    it 'coerces a non-true-or-false argument to false' do
      config.transitive_load_tracking('yes')

      expect(config.transitive_load_tracking).to be(false)
    end

    it 'honors RSPEC_TRACER_TRANSITIVE_LOAD_TRACKING=false over the DSL' do
      stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_TRANSITIVE_LOAD_TRACKING' => 'false'))

      expect(config.transitive_load_tracking(true)).to be(false)
    end

    it 'treats any non-"false" ENV value as true (default-true semantics)' do
      stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_TRANSITIVE_LOAD_TRACKING' => 'true'))

      expect(config.transitive_load_tracking(false)).to be(true)
    end

    it 'memoizes across no-arg reads' do
      config.transitive_load_tracking(false)
      first = config.transitive_load_tracking
      second = config.transitive_load_tracking

      expect([first, second]).to eq([false, false])
    end

    it 'keeps the previous value when re-called with nil' do
      config.transitive_load_tracking(false)
      config.transitive_load_tracking(nil)

      expect(config.transitive_load_tracking).to be(false)
    end
  end

  describe '#track_ar_schema_notifications / #track_ar_schema_notifications?' do
    it 'defaults to false when never configured' do
      expect(config.track_ar_schema_notifications?).to be(false)
    end

    it 'opts in via a bare DSL call' do
      config.track_ar_schema_notifications

      expect(config.track_ar_schema_notifications?).to be(true)
    end

    it 'opts in via an explicit true' do
      config.track_ar_schema_notifications(true)

      expect(config.track_ar_schema_notifications?).to be(true)
    end

    it 'opts out via an explicit false' do
      config.track_ar_schema_notifications(true)
      config.track_ar_schema_notifications(false)

      expect(config.track_ar_schema_notifications?).to be(false)
    end

    it 'coerces any non-true arg to false' do
      config.track_ar_schema_notifications('yes')

      expect(config.track_ar_schema_notifications?).to be(false)
    end

    it 'honors RSPEC_TRACER_AR_SCHEMA_NOTIFICATIONS=true over the DSL' do
      config.track_ar_schema_notifications(false)
      stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_AR_SCHEMA_NOTIFICATIONS' => 'true'))

      expect(config.track_ar_schema_notifications?).to be(true)
    end

    it 'treats any non-"true" ENV value as false' do
      config.track_ar_schema_notifications(true)
      stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_AR_SCHEMA_NOTIFICATIONS' => '1'))

      expect(config.track_ar_schema_notifications?).to be(false)
    end
  end

  describe '#add_filter' do
    # Uses the isolated `config` instance (Class.new { include Configuration })
    # rather than the global RSpecTracer constant so a registered filter
    # does not leak into the production at-exit processing that fires
    # after this suite completes.

    context 'with a block' do
      it 'forwards the block through the DSL wrapper and registers a filter' do
        expect do
          config.add_filter { |source_file| source_file[:file_name].include?('/vendor/bundle/') }
        end.to change { config.filters.size }.by(1)
      end
    end

    context 'with a string argument' do
      it 'registers a filter without a block' do
        expect do
          config.add_filter('/some/path/')
        end.to change { config.filters.size }.by(1)
      end
    end

    context 'with neither argument nor block' do
      it 'raises ArgumentError' do
        expect { config.add_filter }.to raise_error(ArgumentError)
      end
    end
  end
end
