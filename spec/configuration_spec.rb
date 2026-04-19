# frozen_string_literal: true

require 'securerandom'

RSpec.describe RSpecTracer::Configuration do
  subject(:config) { clazz.new }

  let(:clazz) { Class.new { include RSpecTracer::Configuration } }

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
