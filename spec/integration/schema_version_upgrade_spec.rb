# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'

require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/schema'

# 1.x -> 2.0 cache schema-version cold-run integration spec.
#
# The 1.x cache shape on disk wrote `last_run.json` WITHOUT a
# `schema_version` field (or under an older numeric value); the 2.0
# JsonBackend's `load_graph` checks `Schema.supported?(stored) &&
# stored == schema_version` and falls through to a cold run with an
# info-level log when the stored shape is incompatible.
#
# Every existing 1.x user hits this code path on first 2.0 upgrade.
# Previously the path was wired but no integration spec exercised the
# actual upgrade ceremony; doctor's `cache_schema_version_check`
# surfaces the state at diagnostic time, but the lib-level handling
# was unverified at integration level. This spec drives the
# JsonBackend with three concrete 1.x-shaped cache fixtures (no
# schema_version field / older numeric / unsupported new shape) and
# asserts the contract:
#
#   - load_graph returns nil (graceful degradation; never raises)
#   - logger.info fires with a 'cold run' message
#   - save_graph still works after the cold-run fallback (next run
#     writes a fresh schema_version-tagged manifest)
#
# Assert on the contract behavior (logger output + nil return +
# post-fallback save), not just on absence-of-raise; raise-free
# runs alone mask cache-persistence bugs.
# rubocop:disable RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/ContextWording
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe 'Storage::JsonBackend 1.x -> 2.0 cache schema cold-run upgrade ceremony' do
  let(:logger) { instance_double(RSpecTracer::Logger, debug: nil, info: nil, warn: nil, error: nil) }
  let(:current_schema) { RSpecTracer::Storage::Schema::CURRENT }

  around do |example|
    Dir.mktmpdir do |dir|
      @cache_path = dir
      example.run
    end
  end

  def write_legacy_manifest(payload)
    FileUtils.mkdir_p(@cache_path)
    File.write(File.join(@cache_path, 'last_run.json'), JSON.dump(payload))
  end

  def write_legacy_run_dir(run_id, files)
    run_dir = File.join(@cache_path, run_id.to_s)
    FileUtils.mkdir_p(run_dir)
    files.each { |name, content| File.write(File.join(run_dir, name), content) }
  end

  def build_backend
    RSpecTracer::Storage::JsonBackend.new(
      cache_path: @cache_path,
      logger: logger
    )
  end

  context 'when the on-disk cache predates schema_version (1.x layout)' do
    before do
      # 1.x layout: last_run.json carries `last_run` + `pid` only,
      # no schema_version field at all. The run dir holds the 10
      # legacy files keyed off `last_run`.
      write_legacy_manifest('last_run' => '20240115T103045', 'pid' => 12_345)
      write_legacy_run_dir(
        '20240115T103045',
        'all_examples.json' => JSON.dump('legacy[1:1]' => { 'description' => '...' })
      )
    end

    it 'falls back to a cold run gracefully' do
      result = build_backend.load_graph(schema_version: current_schema)

      expect(result).to be_nil
    end

    it 'emits an info-level cold-run log line that names the mismatch' do
      build_backend.load_graph(schema_version: current_schema)

      expect(logger).to have_received(:info)
        .with(a_string_including('schema_version mismatch').and(a_string_including('cold run')))
    end
  end

  context 'when the on-disk cache carries an older numeric schema (e.g. 1 or 2)' do
    before do
      write_legacy_manifest('schema_version' => 1, 'run_id' => 'old-run')
      write_legacy_run_dir('old-run', 'all_examples.json' => JSON.dump({}))
    end

    it 'falls back to cold run + logs the version delta' do
      result = build_backend.load_graph(schema_version: current_schema)

      expect(result).to be_nil
      expect(logger).to have_received(:info)
        .with(a_string_including('stored=1').and(a_string_including('cold run')))
    end
  end

  context 'when the on-disk cache carries the 2.0.0.pre.1 schema (3)' do
    before do
      write_legacy_manifest('schema_version' => 3, 'run_id' => 'pre1-run')
      write_legacy_run_dir('pre1-run', 'all_examples.json' => JSON.dump({}))
    end

    # The 2.0.0.pre.1 -> pre.2 example-identity change reshaped the
    # cache; a pre.1 cache (schema_version 3) must trigger one clean
    # cold run, not a crash, on the pre.2 upgrade.
    it 'falls back to cold run + logs the version delta' do
      result = build_backend.load_graph(schema_version: current_schema)

      expect(result).to be_nil
      expect(logger).to have_received(:info)
        .with(a_string_including('stored=3').and(a_string_including('cold run')))
    end
  end

  context 'when the on-disk cache carries the schema reshaped by #209 (4)' do
    before do
      write_legacy_manifest('schema_version' => 4, 'run_id' => 'schema4-run')
      write_legacy_run_dir('schema4-run', 'all_examples.json' => JSON.dump({}))
    end

    # schema_version 5 reshaped unnamed-example identity (issue #210);
    # a schema-4 cache (the window between #209 and the #210 fix) must
    # trigger one clean cold run, not a crash, on the upgrade.
    it 'falls back to cold run + logs the version delta' do
      result = build_backend.load_graph(schema_version: current_schema)

      expect(result).to be_nil
      expect(logger).to have_received(:info)
        .with(a_string_including('stored=4').and(a_string_including('cold run')))
    end
  end

  context 'when the on-disk cache carries a future / unsupported schema' do
    before do
      write_legacy_manifest('schema_version' => 999_999, 'run_id' => 'future-run')
    end

    it 'falls back to cold run rather than crashing on the unknown shape' do
      result = build_backend.load_graph(schema_version: current_schema)

      expect(result).to be_nil
      expect(logger).to have_received(:info).with(a_string_including('cold run'))
    end
  end

  context 'after the cold-run fallback fires' do
    let(:backend) { build_backend }
    let(:current_run_id) { 'fresh-run-2.0' }

    before do
      # Drop a 1.x-shaped manifest so load_graph returns nil + logs.
      write_legacy_manifest('last_run' => '20240115T103045')
      backend.load_graph(schema_version: current_schema)
    end

    # The cold-run fallback must not corrupt the cache directory
    # so the NEXT run's save_graph writes a fresh schema_version-
    # tagged manifest cleanly. Mirrors the user's experience:
    # first run after upgrade is silent cold, second run is warm
    # against the 2.0 schema.
    it 'allows save_graph to write a fresh 2.0 manifest on the next run' do
      empty_snapshot = RSpecTracer::Storage::Snapshot.empty(
        schema_version: current_schema, run_id: current_run_id
      )

      backend.save_graph(empty_snapshot, schema_version: current_schema)

      manifest = JSON.parse(File.read(File.join(@cache_path, 'last_run.json')))
      expect(manifest['schema_version']).to eq(current_schema)
      expect(manifest['run_id']).to eq(current_run_id)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/ContextWording
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
