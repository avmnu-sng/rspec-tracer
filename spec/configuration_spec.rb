# frozen_string_literal: true

require 'securerandom'

RSpec.describe RSpecTracer::Configuration do
  let(:clazz) { Class.new { include RSpecTracer::Configuration } }
  let(:config) { clazz.new }

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
        expect(config.cache_path).to eq("#{Dir.getwd}/rspec_tracer_cache/")
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
        expect(config.coverage_path).to eq("#{Dir.getwd}/rspec_tracer_coverage/")
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
        expect(config.coverage_tracked_files).to eq(nil)
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
          expect(config.coverage_tracked_files).to eq(nil)
        end
      end
    end
  end
end
