# frozen_string_literal: true

require 'spec_helper'
require 'bundler'
require 'fileutils'
require 'open3'
require 'tmpdir'

# 2.0 deprecation-warning integration coverage.
#
# Two deprecated DSL methods + their env-var twins ship with one-time
# `logger.warn` lines pointing at the replacement, AND continue to
# resolve to the new semantics so 1.x configs keep working:
#
#   reports_s3_path(uri)       -> remote_cache_uri(uri)
#   use_local_aws(bool)        -> remote_cache_backend :s3, local: bool
#   RSPEC_TRACER_REPORTS_S3_PATH -> RSPEC_TRACER_REMOTE_CACHE_URI
#   RSPEC_TRACER_USE_LOCAL_AWS   -> remote_cache_backend params
#
# Each context drives a subprocess `bundle exec rspec` with
# `RSPEC_TRACER_LOG_LEVEL=warn`, captures stderr, and asserts both:
#   (a) the deprecation warn line fires once
#   (b) the deprecated value still resolves (the configuration accessor
#       returns the value the user set, proving back-compat semantics)
#
# Hermetic tmpdir invocation (no fixture dependency) modelled after
# `spec/integration/non_git_repo_spec.rb`.
#
# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe 'deprecated config-DSL + env-var warnings' do
  let(:project_root) { File.expand_path('../..', __dir__) }
  let(:gemfile_path) { File.join(project_root, 'Gemfile') }

  # Each spec body asserts the configured value after RSpecTracer.start
  # has loaded `.rspec-tracer`. The assertion proves the deprecated
  # accessor still returns the user-set value (semantic back-compat),
  # and the `puts` line lets the parent capture-and-grep on stderr
  # for the warn text.
  def smoke_spec(body)
    <<~RUBY
      require "rspec_tracer"
      RSpecTracer.start

      RSpec.describe "deprecation smoke" do
        #{body}
      end
    RUBY
  end

  def run_in_tmpdir(env_overrides:, dotrspec_tracer:, spec_body:)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, '.rspec-tracer'), dotrspec_tracer)
      spec_path = File.join(dir, 'deprecation_smoke_spec.rb')
      File.write(spec_path, smoke_spec(spec_body))

      out, status = Bundler.with_unbundled_env do
        env = {
          'BUNDLE_GEMFILE' => gemfile_path,
          'RSPEC_TRACER_LOG_LEVEL' => 'warn',
          'GIT_DEFAULT_BRANCH' => nil,
          'GIT_BRANCH' => nil,
          'RSPEC_TRACER_REPORTS_S3_PATH' => nil,
          'RSPEC_TRACER_USE_LOCAL_AWS' => nil
        }.merge(env_overrides)
        Open3.capture2e(env, 'bundle', 'exec', 'rspec', '--no-color', spec_path,
                        chdir: dir)
      end

      # Subprocess stdout may include non-ASCII glyphs (rspec progress
      # dots, terminal-reporter separators); force UTF-8 so subsequent
      # String#scan / String#include? do not raise under US-ASCII.
      [out.dup.force_encoding('UTF-8'), status]
    end
  end

  describe 'reports_s3_path DSL' do
    it 'fires deprecation warn AND preserves the configured value' do
      out, status = run_in_tmpdir(
        env_overrides: {},
        dotrspec_tracer: <<~CONFIG,
          RSpecTracer.configure do
            reports_s3_path 's3://my-bucket/rspec-tracer'
          end
        CONFIG
        spec_body: <<~BODY
          it 'preserves reports_s3_path under the deprecated DSL' do
            expect(RSpecTracer.reports_s3_path).to eq('s3://my-bucket/rspec-tracer')
          end
        BODY
      )

      expect(status.success?).to(be(true), "rspec failed:\n#{out}")
      expect(out).to include('rspec-tracer deprecation:')
      expect(out).to include('reports_s3_path')
    end
  end

  describe 'RSPEC_TRACER_REPORTS_S3_PATH env var' do
    it 'fires deprecation warn when the bare DSL accessor reads the env value' do
      out, status = run_in_tmpdir(
        env_overrides: { 'RSPEC_TRACER_REPORTS_S3_PATH' => 's3://env-bucket/path' },
        dotrspec_tracer: <<~CONFIG,
          RSpecTracer.configure do
            reports_s3_path
          end
        CONFIG
        spec_body: <<~BODY
          it 'reads RSPEC_TRACER_REPORTS_S3_PATH through the deprecated accessor' do
            expect(RSpecTracer.reports_s3_path).to eq('s3://env-bucket/path')
          end
        BODY
      )

      expect(status.success?).to(be(true), "rspec failed:\n#{out}")
      expect(out).to include('rspec-tracer deprecation:')
      expect(out).to include('REPORTS_S3_PATH')
    end
  end

  describe 'use_local_aws DSL' do
    it 'fires deprecation warn AND preserves the configured value' do
      out, status = run_in_tmpdir(
        env_overrides: {},
        dotrspec_tracer: <<~CONFIG,
          RSpecTracer.configure do
            use_local_aws true
          end
        CONFIG
        spec_body: <<~BODY
          it 'preserves use_local_aws under the deprecated DSL' do
            expect(RSpecTracer.use_local_aws).to be(true)
          end
        BODY
      )

      expect(status.success?).to(be(true), "rspec failed:\n#{out}")
      expect(out).to include('rspec-tracer deprecation:')
      expect(out).to include('use_local_aws')
    end
  end

  describe 'RSPEC_TRACER_USE_LOCAL_AWS env var' do
    it 'fires deprecation warn when the bare DSL accessor reads the env value' do
      out, status = run_in_tmpdir(
        env_overrides: { 'RSPEC_TRACER_USE_LOCAL_AWS' => 'true' },
        dotrspec_tracer: <<~CONFIG,
          RSpecTracer.configure do
            use_local_aws
          end
        CONFIG
        spec_body: <<~BODY
          it 'reads RSPEC_TRACER_USE_LOCAL_AWS through the deprecated accessor' do
            expect(RSpecTracer.use_local_aws).to be(true)
          end
        BODY
      )

      expect(status.success?).to(be(true), "rspec failed:\n#{out}")
      expect(out).to include('rspec-tracer deprecation:')
      expect(out).to include('USE_LOCAL_AWS')
    end
  end

  describe '.rspec-tracer file with both deprecated options' do
    it 'fires both deprecation warns AND resolves both values from a single config load' do
      out, status = run_in_tmpdir(
        env_overrides: {},
        dotrspec_tracer: <<~CONFIG,
          RSpecTracer.configure do
            reports_s3_path 's3://combined-bucket/path'
            use_local_aws true
          end
        CONFIG
        spec_body: <<~BODY
          it 'resolves both deprecated options under a single .rspec-tracer load' do
            expect(RSpecTracer.reports_s3_path).to eq('s3://combined-bucket/path')
            expect(RSpecTracer.use_local_aws).to be(true)
          end
        BODY
      )

      expect(status.success?).to(be(true), "rspec failed:\n#{out}")
      warn_count = out.scan('rspec-tracer deprecation:').size
      expect(warn_count).to be >= 2
      expect(out).to include('reports_s3_path')
      expect(out).to include('use_local_aws')
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
