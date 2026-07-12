# frozen_string_literal: true

require 'spec_helper'
require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# Real-user-shape integration coverage for `RSPEC_TRACER_STORAGE`
# env-var precedence over the `storage_backend` DSL.
#
# Discriminator: each backend writes a different file shape under
# `rspec_tracer_cache/`:
#   :json   -> `last_run.json` (manifest) + per-field `*.json` files
#              under `<run_id>/` (no `rspec_tracer.sqlite3`).
#   :sqlite -> `rspec_tracer.sqlite3` database file (no `last_run.json`,
#              no per-field JSON under `<run_id>/`; the manifest
#              pointer lives inside the DB).
#
# Both contexts assert on the on-disk cache layout (filesystem
# state), not just exit code -- exit-status-only checks mask
# cache-persistence bugs.
#
# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe 'RSPEC_TRACER_STORAGE env-var override integration' do
  let(:project_root) { File.expand_path('../..', __dir__) }
  let(:gemfile_path) { File.join(project_root, 'Gemfile') }

  let(:fixture_spec_body) do
    <<~RUBY
      RSpec.describe 'storage backend dispatch fixture' do
        it 'runs example one' do
          expect(1 + 1).to eq(2)
        end

        it 'runs example two' do
          expect(true).to be(true)
        end
      end
    RUBY
  end

  def write_fixture(dir, dsl_storage:)
    File.write(File.join(dir, '.rspec-tracer'), <<~RUBY)
      # frozen_string_literal: true
      RSpecTracer.configure do
        storage_backend :#{dsl_storage}
      end
    RUBY
    File.write(File.join(dir, 'spec_helper.rb'), <<~RUBY)
      require 'rspec_tracer'
      RSpecTracer.start
    RUBY
    File.write(File.join(dir, 'storage_spec.rb'), <<~RUBY)
      require_relative 'spec_helper'
      #{fixture_spec_body}
    RUBY
  end

  def run_rspec(dir, env_overrides: {})
    Bundler.with_unbundled_env do
      env = {
        'BUNDLE_GEMFILE' => gemfile_path,
        'GIT_DEFAULT_BRANCH' => nil,
        'GIT_BRANCH' => nil,
        'RSPEC_TRACER_STORAGE' => nil
      }.merge(env_overrides)
      Open3.capture2e(env, 'bundle', 'exec', 'rspec', '--no-color', 'storage_spec.rb',
                      chdir: dir)
    end
  end

  def cache_layout(dir)
    cache_dir = File.join(dir, 'rspec_tracer_cache')
    return { dir_present: false } unless Dir.exist?(cache_dir)

    sqlite_present = File.exist?(File.join(cache_dir, 'rspec_tracer.sqlite3'))
    manifest_path = File.join(cache_dir, 'last_run.json')
    json_field_count = if File.exist?(manifest_path)
                         manifest = JSON.parse(File.read(manifest_path, encoding: 'UTF-8'))
                         run_id = manifest.fetch('run_id')
                         run_dir = File.join(cache_dir, run_id)
                         Dir.exist?(run_dir) ? Dir[File.join(run_dir, '*.json')].size : 0
                       else
                         0
                       end

    {
      dir_present: true,
      json_manifest_present: File.exist?(manifest_path),
      sqlite_present: sqlite_present,
      json_field_count: json_field_count
    }
  end

  context 'when RSPEC_TRACER_STORAGE=sqlite overrides the DSL :json' do
    it 'env wins - writes rspec_tracer.sqlite3, NO last_run.json + NO per-field JSON' do
      Dir.mktmpdir do |dir|
        write_fixture(dir, dsl_storage: 'json')

        out, status = run_rspec(dir, env_overrides: { 'RSPEC_TRACER_STORAGE' => 'sqlite' })

        expect(status.success?).to(
          be(true),
          "expected zero exit, got #{status.exitstatus}:\n#{out}"
        )
        layout = cache_layout(dir)
        expect(layout[:sqlite_present]).to(
          be(true),
          "expected rspec_tracer.sqlite3 with env=sqlite override, got: #{layout.inspect}\n#{out}"
        )
        expect(layout[:json_manifest_present]).to(
          be(false),
          "sqlite backend should not write last_run.json (manifest lives in the DB), got: #{layout.inspect}"
        )
        expect(layout[:json_field_count]).to eq(0)
      end
    end
  end

  context 'when RSPEC_TRACER_STORAGE=json overrides the DSL :sqlite' do
    it 'env wins - writes last_run.json + per-field JSON files, NO rspec_tracer.sqlite3' do
      Dir.mktmpdir do |dir|
        write_fixture(dir, dsl_storage: 'sqlite')

        out, status = run_rspec(dir, env_overrides: { 'RSPEC_TRACER_STORAGE' => 'json' })

        expect(status.success?).to(
          be(true),
          "expected zero exit, got #{status.exitstatus}:\n#{out}"
        )
        layout = cache_layout(dir)
        expect(layout[:json_manifest_present]).to be(true)
        expect(layout[:sqlite_present]).to(
          be(false),
          "expected no rspec_tracer.sqlite3 with env=json override, got: #{layout.inspect}\n#{out}"
        )
        expect(layout[:json_field_count]).to(
          be > 0,
          "expected per-field JSON files with json backend, got: #{layout.inspect}\n#{out}"
        )
      end
    end
  end

  context 'when RSPEC_TRACER_STORAGE is absent (DSL alone decides)' do
    it 'DSL :sqlite produces sqlite layout when env is unset' do
      Dir.mktmpdir do |dir|
        write_fixture(dir, dsl_storage: 'sqlite')

        out, status = run_rspec(dir)

        expect(status.success?).to(
          be(true),
          "expected zero exit, got #{status.exitstatus}:\n#{out}"
        )
        layout = cache_layout(dir)
        expect(layout[:sqlite_present]).to(
          be(true),
          "expected rspec_tracer.sqlite3 from DSL :sqlite (env unset), got: #{layout.inspect}\n#{out}"
        )
        expect(layout[:json_manifest_present]).to be(false)
        expect(layout[:json_field_count]).to eq(0)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
