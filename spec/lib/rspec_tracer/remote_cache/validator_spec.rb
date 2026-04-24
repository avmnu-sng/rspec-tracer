# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RSpecTracer::RemoteCache::Validator do
  subject(:validator) { described_class.new }

  let(:envs) { %w[TEST_SUITE_ID TEST_SUITES] }

  before { envs.each { |env| ENV.delete(env) } }
  after  { envs.each { |env| ENV.delete(env) } }

  describe '#initialize' do
    context 'when TEST_SUITE_ID is set but TEST_SUITES is not' do
      before { ENV['TEST_SUITE_ID'] = '1' }

      it 'raises ValidationError with correct "environment" spelling' do
        expect { validator }.to raise_error(
          RSpecTracer::RemoteCache::Validator::ValidationError,
          /Both the environment variables TEST_SUITE_ID and TEST_SUITES are not set/
        )
      end
    end

    context 'when TEST_SUITES is set but TEST_SUITE_ID is not' do
      before { ENV['TEST_SUITES'] = '3' }

      it 'raises ValidationError' do
        expect { validator }.to raise_error(RSpecTracer::RemoteCache::Validator::ValidationError)
      end
    end

    context 'when neither env var is set' do
      it 'initializes in single-suite mode without raising' do
        expect { validator }.not_to raise_error
      end
    end

    context 'when both env vars are set' do
      before do
        ENV['TEST_SUITE_ID'] = '2'
        ENV['TEST_SUITES']   = '3'
      end

      it 'initializes in multi-suite mode without raising' do
        expect { validator }.not_to raise_error
      end
    end
  end

  describe '#valid?' do
    let(:ref) { 'abcdef1234' }

    context 'when in single-suite mode' do
      let(:run_hash) { '0' * 32 }
      let(:cache_files) do
        [
          "2024-01-01 00:00:00  0 /#{ref}/last_run.json",
          *Array.new(described_class::CACHE_FILES_PER_TEST_SUITE) do |i|
            "2024-01-01 00:00:00  0 /#{ref}/#{run_hash}/file_#{i}.json"
          end
        ]
      end

      it 'returns true when the expected last_run.json and N cache files are present' do
        expect(validator.valid?(ref, cache_files)).to be(true)
      end

      it 'returns false when a cache file is missing' do
        expect(validator.valid?(ref, cache_files[0..-2])).to be(false)
      end

      it 'does not match files with extensions beyond .json (e.g. .json.backup) — $ anchor regression' do
        poisoned = cache_files.dup
        poisoned[-1] = "2024-01-01 00:00:00  0 /#{ref}/#{run_hash}/file_10.json.backup"
        expect(validator.valid?(ref, poisoned)).to be(false)
      end
    end

    context 'when in multi-suite mode' do
      let(:run_hash) { '0' * 32 }
      let(:cache_files) do
        [
          "2024-01-01 00:00:00  0 /#{ref}/1/last_run.json",
          "2024-01-01 00:00:00  0 /#{ref}/2/last_run.json",
          "2024-01-01 00:00:00  0 /#{ref}/3/last_run.json",
          *(1..3).flat_map do |suite|
            Array.new(described_class::CACHE_FILES_PER_TEST_SUITE) do |i|
              "2024-01-01 00:00:00  0 /#{ref}/#{suite}/#{run_hash}/file_#{i}.json"
            end
          end
        ]
      end

      before do
        ENV['TEST_SUITE_ID'] = '2'
        ENV['TEST_SUITES']   = '3'
      end

      it 'returns true when every suite has its full cache' do
        expect(validator.valid?(ref, cache_files)).to be(true)
      end

      it 'returns false when one suite is missing its last_run.json (aborted suite)' do
        partial = cache_files.reject { |f| f.include?("/#{ref}/3/last_run.json") }
        expect(validator.valid?(ref, partial)).to be(false)
      end
    end
  end
end
