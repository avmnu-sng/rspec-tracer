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

  describe 'unknown DSL method handling (M8.9)' do
    # Typos in `.rspec-tracer` previously raised bare `NoMethodError`
    # with a Ruby backtrace. Now they raise `InvalidUsageError` with
    # a stdlib `DidYouMean` suggestion when the typo is close to a
    # real DSL method; falls through to NoMethodError when no close
    # match exists so internal `respond_to?` probes retain standard
    # Ruby semantics.
    it 'raises InvalidUsageError on a typo with a did-you-mean suggestion' do
      expect { RSpecTracer.track_files_glob('config/**/*') }
        .to raise_error(
          RSpecTracer::Configuration::InvalidUsageError,
          /unknown \.rspec-tracer DSL method :track_files_glob.*did you mean.*track_files/
        )
    end

    it 'falls through to NoMethodError when no close match exists' do
      expect { RSpecTracer.zzzbogus('x') }
        .to raise_error(NoMethodError)
    end

    it 'falls through to NoMethodError on assignment-style calls' do
      expect { RSpecTracer.send(:totally_unknown=, 'x') }
        .to raise_error(NoMethodError)
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

    it 'prevents subsequent track_env calls' do
      config.track_env('AUTH_TOKEN')
      config.freeze_declared_globs!

      expect { config.track_env('OTHER') }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /cannot be called/)
    end

    it 'keeps previously-declared env names readable after freezing' do
      config.track_env('AUTH_TOKEN')
      config.freeze_declared_globs!

      expect(config.tracked_env_names).to eq(['AUTH_TOKEN'])
    end
  end

  describe '#track_env' do
    it 'returns an empty list when never configured' do
      expect(config.tracked_env_names).to eq([])
    end

    it 'accumulates names across multiple calls' do
      config.track_env('AUTH_TOKEN')
      config.track_env('ROLE_CONFIG')

      expect(config.tracked_env_names).to eq(%w[AUTH_TOKEN ROLE_CONFIG])
    end

    it 'accepts multiple names per call' do
      config.track_env('A', 'B')

      expect(config.tracked_env_names).to eq(%w[A B])
    end

    it 'flattens nested arrays' do
      config.track_env(%w[A B])

      expect(config.tracked_env_names).to eq(%w[A B])
    end

    it 'coerces non-string entries to strings (Symbol support)' do
      config.track_env(:AUTH_TOKEN)

      expect(config.tracked_env_names).to eq(['AUTH_TOKEN'])
    end

    it 'drops nil entries silently' do
      config.track_env(nil, 'AUTH_TOKEN', nil)

      expect(config.tracked_env_names).to eq(['AUTH_TOKEN'])
    end

    it 'preserves duplicates in the accumulator (Engine de-dupes downstream via EnvMatcher.expand.uniq)' do
      config.track_env('AUTH_TOKEN')
      config.track_env('AUTH_TOKEN')

      expect(config.tracked_env_names).to eq(%w[AUTH_TOKEN AUTH_TOKEN])
    end

    it 'accepts wildcard patterns as opaque strings (validation happens in EnvMatcher.expand)' do
      config.track_env('RAILS_*')

      expect(config.tracked_env_names).to eq(['RAILS_*'])
    end

    it 'returns a frozen view from the setter' do
      result = config.track_env('AUTH_TOKEN')

      expect(result).to be_frozen
    end

    it 'returns a frozen view from the reader' do
      config.track_env('AUTH_TOKEN')

      expect(config.tracked_env_names).to be_frozen
    end

    it 'returns a frozen empty array from the reader when never set' do
      result = config.tracked_env_names

      expect(result).to be_frozen
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

    it 'accepts :sqlite as a backend name' do
      expect(config.storage_backend(:sqlite)).to eq(:sqlite)
    end

    describe 'opts validation' do
      it 'stores serializer: :msgpack for the :json backend' do
        config.storage_backend(:json, serializer: :msgpack)

        expect(config.storage_backend_opts).to eq(serializer: :msgpack)
      end

      it 'defaults storage_backend_opts to an empty hash' do
        expect(config.storage_backend_opts).to eq({})
      end

      it 'freezes the default storage_backend_opts hash' do
        expect(config.storage_backend_opts).to be_frozen
      end

      it 'defaults serializer to :json when :json is chosen without opts' do
        config.storage_backend(:json)

        expect(config.storage_backend_opts).to eq(serializer: :json)
      end

      it 'rejects an unknown opt key' do
        expect { config.storage_backend(:json, foo: :bar) }
          .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /unknown storage_backend options/)
      end

      it 'rejects an unknown serializer' do
        expect { config.storage_backend(:json, serializer: :toml) }
          .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /unknown storage serializer/)
      end

      it 'rejects any opts for the :sqlite backend' do
        expect { config.storage_backend(:sqlite, serializer: :msgpack) }
          .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /sqlite does not accept options/)
      end

      it 'honors RSPEC_TRACER_STORAGE_SERIALIZER over the opt' do
        stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_STORAGE_SERIALIZER' => 'msgpack'))
        config.storage_backend(:json, serializer: :json)

        expect(config.storage_backend_opts).to eq(serializer: :msgpack)
      end
    end
  end

  # rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength
  describe '#ignore_spec_files' do
    it 'returns a frozen empty array when never configured' do
      result = config.ignore_spec_files

      expect(result).to eq([])
      expect(result).to be_frozen
    end

    it 'accumulates passed globs across calls' do
      config.ignore_spec_files('spec/smoke/**/*_spec.rb')
      config.ignore_spec_files('spec/legacy/**/*_spec.rb')

      expect(config.ignore_spec_files).to contain_exactly(
        'spec/smoke/**/*_spec.rb',
        'spec/legacy/**/*_spec.rb'
      )
    end

    it 'accepts mixed single-arg and splat forms and flattens nested arrays' do
      config.ignore_spec_files('spec/a_spec.rb', ['spec/b_spec.rb', 'spec/c_spec.rb'])

      expect(config.ignore_spec_files).to contain_exactly(
        'spec/a_spec.rb', 'spec/b_spec.rb', 'spec/c_spec.rb'
      )
    end

    it 'coerces all entries to strings (supports Pathname etc)' do
      config.ignore_spec_files(Pathname('spec/x_spec.rb'))

      expect(config.ignore_spec_files).to eq(['spec/x_spec.rb'])
    end

    it 'drops nil entries silently' do
      config.ignore_spec_files('spec/a.rb', nil, 'spec/b.rb')

      expect(config.ignore_spec_files).to contain_exactly('spec/a.rb', 'spec/b.rb')
    end

    it 'freezes the returned array so downstream consumers treat it as immutable' do
      config.ignore_spec_files('spec/a.rb')

      expect(config.ignore_spec_files).to be_frozen
    end
  end

  describe '#ignore_spec_file?' do
    it 'returns false when file_path is nil' do
      expect(config.ignore_spec_file?(nil)).to be(false)
    end

    it 'returns false when file_path is empty' do
      expect(config.ignore_spec_file?('')).to be(false)
    end

    it 'returns false when no globs are configured' do
      expect(config.ignore_spec_file?('spec/foo_spec.rb')).to be(false)
    end

    it 'returns true on a direct glob match against the raw RSpec-shaped path' do
      config.ignore_spec_files('spec/smoke/**/*_spec.rb')

      expect(config.ignore_spec_file?('./spec/smoke/login_spec.rb')).to be(true)
    end

    it 'returns true after stripping a leading ./ from the RSpec-shaped path' do
      config.ignore_spec_files('spec/legacy/**/*')

      expect(config.ignore_spec_file?('./spec/legacy/old_spec.rb')).to be(true)
    end

    it 'returns true when matched via a root-relative normalization of an absolute path' do
      config.root('/tmp/project')
      config.ignore_spec_files('spec/smoke/**/*_spec.rb')

      expect(config.ignore_spec_file?('/tmp/project/spec/smoke/login_spec.rb')).to be(true)
    end

    it 'returns false when no glob matches' do
      config.ignore_spec_files('spec/legacy/**/*_spec.rb')

      expect(config.ignore_spec_file?('./spec/regular/foo_spec.rb')).to be(false)
    end
  end
  # rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength

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

  describe '#add_reporter / #reporters (M6.1)' do
    before { require 'rspec_tracer/reporters/registry' }

    it 'returns nil for reporters when never configured' do
      expect(config.reporters).to be_nil
    end

    it 'accumulates [name, opts] tuples across calls' do
      config.add_reporter(:terminal)
      config.add_reporter(:json)

      expect(config.reporters.map(&:first)).to eq(%i[terminal json])
    end

    it 'passes **opts through to the reporter entry' do
      config.add_reporter(:json, indent: 4)

      expect(config.reporters.first.last).to eq(indent: 4)
    end

    it 'freezes the returned array' do
      config.add_reporter(:terminal)

      expect(config.reporters).to be_frozen
    end

    it 'raises InvalidUsageError on an unknown symbol' do
      expect { config.add_reporter(:bogus) }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /unknown reporter/)
    end

    it 'raises InvalidUsageError on a non-Symbol / non-Class argument' do
      expect { config.add_reporter(42) }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /expected Symbol or Class/)
    end

    it 'accepts a Class value (custom reporter)' do
      custom_class = Class.new

      config.add_reporter(custom_class)

      expect(config.reporters.first.first).to eq(custom_class)
    end

    it 'returns the (frozen) current list from add_reporter' do
      result = config.add_reporter(:terminal)

      expect(result).to be_frozen
    end

    it 'tolerates reporter validation when Registry is not loaded (fallback to no allowed)' do
      hide_const('RSpecTracer::Reporters::Registry')

      expect { config.add_reporter(:terminal) }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /unknown reporter/)
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

  describe '#remote_cache_backend' do
    it 'stores a [name, opts] pair' do
      config.remote_cache_backend(:s3, bucket: 'b', prefix: 'p')

      expect(config.remote_cache_backend_entry).to eq([:s3, { bucket: 'b', prefix: 'p' }])
    end

    it 'accepts a Class value' do
      backend_class = Class.new
      config.remote_cache_backend(backend_class, some_opt: 1)

      expect(config.remote_cache_backend_entry).to eq([backend_class, { some_opt: 1 }])
    end

    it 'raises when called a second time' do
      config.remote_cache_backend(:s3, bucket: 'b', prefix: 'p')

      expect { config.remote_cache_backend(:s3, bucket: 'other') }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /already configured/)
    end

    it 'rejects invalid name types' do
      expect { config.remote_cache_backend('not-symbol-or-class') }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /Symbol or Class/)
    end

    it 'returns nil from the reader when never set' do
      expect(config.remote_cache_backend_entry).to be_nil
    end
  end

  describe '#remote_cache_uri' do
    it 'parses an s3:// URI and delegates to remote_cache_backend' do
      config.remote_cache_uri('s3://my-bucket/my/prefix')

      expect(config.remote_cache_backend_entry)
        .to eq([:s3, { bucket: 'my-bucket', prefix: 'my/prefix' }])
    end

    it 'reads RSPEC_TRACER_REMOTE_CACHE_URI when no arg is given' do
      stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_REMOTE_CACHE_URI' => 's3://env-bucket/env-prefix'))
      config.remote_cache_uri

      expect(config.remote_cache_backend_entry)
        .to eq([:s3, { bucket: 'env-bucket', prefix: 'env-prefix' }])
    end

    it 'rejects unsupported schemes' do
      expect { config.remote_cache_uri('ftp://bucket/x') }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /unsupported.*scheme/)
    end

    it 'rejects URIs without a host' do
      expect { config.remote_cache_uri('s3://') }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /invalid remote_cache_uri/)
    end

    it 'rejects malformed URIs' do
      expect { config.remote_cache_uri('this-is-not-a-uri ${whatever}') }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /invalid remote_cache_uri/)
    end
  end

  describe '#cache_retention_count' do
    it 'stores a positive integer' do
      config.cache_retention_count(100)

      expect(config.cache_retention_count).to eq(100)
    end

    it 'rejects zero' do
      expect { config.cache_retention_count(0) }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /positive integer/)
    end

    it 'rejects non-integers' do
      expect { config.cache_retention_count('100') }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /positive integer/)
    end

    it 'raises when cache_retention_duration is already set' do
      config.cache_retention_duration('30 days')

      expect { config.cache_retention_count(100) }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /mutually exclusive/)
    end

    it 'returns nil when not set' do
      expect(config.cache_retention_count).to be_nil
    end
  end

  describe '#cache_retention_duration' do
    it 'stores an integer as seconds directly' do
      config.cache_retention_duration(3600)

      expect(config.cache_retention_duration_seconds).to eq(3600)
    end

    it 'parses "30 days"' do
      config.cache_retention_duration('30 days')

      expect(config.cache_retention_duration_seconds).to eq(30 * 86_400)
    end

    it 'parses "2 weeks"' do
      config.cache_retention_duration('2 weeks')

      expect(config.cache_retention_duration_seconds).to eq(2 * 604_800)
    end

    it 'parses "1 hour"' do
      config.cache_retention_duration('1 hour')

      expect(config.cache_retention_duration_seconds).to eq(3600)
    end

    it 'parses "60 seconds"' do
      config.cache_retention_duration('60 seconds')

      expect(config.cache_retention_duration_seconds).to eq(60)
    end

    it 'parses "15 minutes"' do
      config.cache_retention_duration('15 minutes')

      expect(config.cache_retention_duration_seconds).to eq(15 * 60)
    end

    it 'rejects malformed strings' do
      expect { config.cache_retention_duration('forever') }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /invalid retention duration/)
    end

    it 'rejects negative integers' do
      expect { config.cache_retention_duration(-1) }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /positive/)
    end

    it 'rejects zero' do
      expect { config.cache_retention_duration('0 days') }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /positive/)
    end

    it 'rejects unsupported input types' do
      expect { config.cache_retention_duration(3.14) }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /invalid retention duration/)
    end

    it 'raises when cache_retention_count is already set' do
      config.cache_retention_count(100)

      expect { config.cache_retention_duration('30 days') }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /mutually exclusive/)
    end

    it 'returns nil from the seconds reader when never set' do
      expect(config.cache_retention_duration_seconds).to be_nil
    end
  end

  describe '#cache_retention_pr_branch_ttl' do
    it 'stores a duration string' do
      config.cache_retention_pr_branch_ttl('14 days')

      expect(config.cache_retention_pr_branch_ttl_seconds).to eq(14 * 86_400)
    end

    it 'returns nil when not set' do
      expect(config.cache_retention_pr_branch_ttl_seconds).to be_nil
    end

    it 'coexists with cache_retention_count (not mutually exclusive)' do
      config.cache_retention_count(100)

      expect { config.cache_retention_pr_branch_ttl('14 days') }.not_to raise_error
    end
  end

  describe '#cache_retention_local_count (M3.8)' do
    it 'defaults to DEFAULT_CACHE_RETENTION_LOCAL_COUNT when never set' do
      expect(config.cache_retention_local_count)
        .to eq(RSpecTracer::Configuration::DEFAULT_CACHE_RETENTION_LOCAL_COUNT)
    end

    it 'stores a non-negative integer' do
      config.cache_retention_local_count(3)
      expect(config.cache_retention_local_count).to eq(3)
    end

    it 'accepts 0 as an opt-out signal' do
      config.cache_retention_local_count(0)
      expect(config.cache_retention_local_count).to eq(0)
    end

    it 'rejects negative integers' do
      expect { config.cache_retention_local_count(-1) }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /non-negative integer/)
    end

    it 'rejects non-integers' do
      expect { config.cache_retention_local_count('5') }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /non-negative integer/)
    end

    it 'honors RSPEC_TRACER_CACHE_RETENTION_LOCAL_COUNT ENV override' do
      stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_CACHE_RETENTION_LOCAL_COUNT' => '2'))
      expect(config.cache_retention_local_count(99)).to eq(2)
    end

    it 'rejects a non-numeric ENV override' do
      stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_CACHE_RETENTION_LOCAL_COUNT' => 'oops'))
      expect { config.cache_retention_local_count }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /non-negative integer/)
    end
  end

  describe '#cache_size_warn_per_file_mb (M3.8)' do
    it 'defaults to DEFAULT_CACHE_SIZE_WARN_PER_FILE_MB when never set' do
      expect(config.cache_size_warn_per_file_mb)
        .to eq(RSpecTracer::Configuration::DEFAULT_CACHE_SIZE_WARN_PER_FILE_MB)
    end

    it 'stores a non-negative integer' do
      config.cache_size_warn_per_file_mb(25)
      expect(config.cache_size_warn_per_file_mb).to eq(25)
    end

    it 'accepts 0 as an opt-out signal' do
      config.cache_size_warn_per_file_mb(0)
      expect(config.cache_size_warn_per_file_mb).to eq(0)
    end

    it 'rejects negative integers' do
      expect { config.cache_size_warn_per_file_mb(-1) }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /non-negative integer/)
    end

    it 'rejects non-integers' do
      expect { config.cache_size_warn_per_file_mb('25') }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /non-negative integer/)
    end

    it 'honors the ENV override' do
      stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_CACHE_SIZE_WARN_PER_FILE_MB' => '10'))
      expect(config.cache_size_warn_per_file_mb).to eq(10)
    end
  end

  describe '#cache_size_warn_total_mb (M3.8)' do
    it 'defaults to DEFAULT_CACHE_SIZE_WARN_TOTAL_MB when never set' do
      expect(config.cache_size_warn_total_mb)
        .to eq(RSpecTracer::Configuration::DEFAULT_CACHE_SIZE_WARN_TOTAL_MB)
    end

    it 'stores a non-negative integer' do
      config.cache_size_warn_total_mb(250)
      expect(config.cache_size_warn_total_mb).to eq(250)
    end

    it 'accepts 0 as an opt-out signal' do
      config.cache_size_warn_total_mb(0)
      expect(config.cache_size_warn_total_mb).to eq(0)
    end

    it 'rejects negative integers' do
      expect { config.cache_size_warn_total_mb(-1) }
        .to raise_error(RSpecTracer::Configuration::InvalidUsageError, /non-negative integer/)
    end

    it 'honors the ENV override' do
      stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_CACHE_SIZE_WARN_TOTAL_MB' => '750'))
      expect(config.cache_size_warn_total_mb).to eq(750)
    end
  end

  describe '#reports_s3_path (deprecated)' do
    it 'still stores a valid s3:// URI' do
      allow(config.logger).to receive(:warn)
      config.reports_s3_path('s3://bucket/prefix')

      expect(config.reports_s3_path).to eq('s3://bucket/prefix')
    end

    it 'emits a one-time deprecation warning' do
      allow(config.logger).to receive(:warn)

      config.reports_s3_path('s3://bucket/prefix')
      config.reports_s3_path('s3://bucket/prefix') # getter path, no warn

      expect(config.logger).to have_received(:warn).with(/reports_s3_path.*deprecated/).once
    end
  end

  describe '#reports_s3_path_set? (probe-path predicate)' do
    it 'returns false when neither the DSL nor the env var is set' do
      stub_const('ENV', ENV.to_hash.except('RSPEC_TRACER_REPORTS_S3_PATH'))

      expect(config.reports_s3_path_set?).to be(false)
    end

    it 'returns true after the DSL set a valid s3:// URI' do
      allow(config.logger).to receive(:warn)
      config.reports_s3_path('s3://bucket/prefix')

      expect(config.reports_s3_path_set?).to be(true)
    end

    it 'returns true when only the env var is set (no DSL call yet)' do
      stub_const('ENV', ENV.to_hash.merge('RSPEC_TRACER_REPORTS_S3_PATH' => 's3://env-bucket/env-prefix'))

      expect(config.reports_s3_path_set?).to be(true)
    end

    it 'does not emit a deprecation warning when probed' do
      stub_const('ENV', ENV.to_hash.except('RSPEC_TRACER_REPORTS_S3_PATH'))
      allow(config.logger).to receive(:warn)

      config.reports_s3_path_set?

      expect(config.logger).not_to have_received(:warn)
    end
  end

  describe '#use_local_aws (deprecated)' do
    it 'still stores a boolean' do
      allow(config.logger).to receive(:warn)
      config.use_local_aws(true)

      expect(config.use_local_aws).to be(true)
    end

    it 'emits a one-time deprecation warning' do
      allow(config.logger).to receive(:warn)

      config.use_local_aws(true)
      config.use_local_aws(true)

      expect(config.logger).to have_received(:warn).with(/use_local_aws.*deprecated/).once
    end
  end
end
