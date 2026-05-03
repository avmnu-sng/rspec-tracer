# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'securerandom'
require 'tmpdir'
require 'uri'

# User-facing Rake-task integration coverage. The 1.x → 2.0 user-facing
# remote-cache flow is `bundle exec rake rspec_tracer:remote_cache:*`,
# loaded from inside the gem via the canonical Rakefile shim:
#
#   spec = Gem::Specification.find_by_name('rspec-tracer')
#   load "#{spec.gem_dir}/lib/rspec_tracer/remote_cache/Rakefile"
#
# `spec/integration/remote_cache_spec.rb` exercises the S3Backend
# round-trip via direct backend calls. This spec drives the same
# round-trip via the rake-task surface, proving:
#   - the Rakefile shim loads cleanly under `rake -f`
#   - task name resolution works (`rspec_tracer:remote_cache:download`,
#     `rspec_tracer:remote_cache:upload`)
#   - env-var propagation reaches UserTasks (REMOTE_CACHE_URI, branch,
#     test_suite_id)
#   - exit behavior matches the 1.x graceful-degradation contract
#
# Skips when LocalStack is unreachable (mirrors remote_cache_spec.rb).
#
# rubocop:disable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/InstanceVariable
# rubocop:disable RSpec/LeakyConstantDeclaration, RSpec/ExampleLength, RSpec/MultipleExpectations
# rubocop:disable Lint/ConstantDefinitionInBlock
RSpec.describe 'rake rspec_tracer:remote_cache:* tasks against LocalStack', :integration, :localstack do
  LOCALSTACK_ENDPOINT_RAKE = ENV.fetch('LOCALSTACK_ENDPOINT', 'http://localhost:4566')

  def localstack_reachable?
    return false unless system('command', '-v', 'awslocal', out: File::NULL, err: File::NULL)

    uri = URI("#{LOCALSTACK_ENDPOINT_RAKE}/_localstack/health")
    Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) do |http|
      response = http.get(uri.request_uri)
      return false unless response.is_a?(Net::HTTPSuccess)

      payload = JSON.parse(response.body)
      %w[available running].include?(payload.dig('services', 's3'))
    end
  rescue StandardError
    false
  end

  before(:all) do
    skip 'LocalStack not reachable; skipping integration specs' unless localstack_reachable?

    @bucket = "rspec-tracer-rake-it-#{SecureRandom.hex(4)}"
    _stdout, stderr, status = Open3.capture3('awslocal', 's3', 'mb', "s3://#{@bucket}")
    raise "failed to create bucket #{@bucket}: #{stderr}" unless status.success?
  end

  after(:all) do
    Open3.capture3('awslocal', 's3', 'rb', "s3://#{@bucket}", '--force') if defined?(@bucket) && @bucket
  end

  let(:project_root) { File.expand_path('../..', __dir__) }
  let(:gemfile_path) { File.join(project_root, 'Gemfile') }

  # Inline Rakefile reproducing the user-facing 1.x pattern from
  # README "Configuring CI". `Gem::Specification.find_by_name` resolves
  # to the in-development gem since `gemspec` is in the outer Gemfile.
  let(:user_rakefile) do
    <<~RAKE
      # frozen_string_literal: true
      spec = Gem::Specification.find_by_name('rspec-tracer')
      load "\#{spec.gem_dir}/lib/rspec_tracer/remote_cache/Rakefile"
    RAKE
  end

  # Minimal .rspec-tracer — explicit `remote_cache_backend :s3` with
  # bucket + prefix so `local: true` reaches the awslocal CLI path
  # (LocalStack endpoint). `remote_cache_uri` parses URIs but does
  # not currently flow `local:` through to the backend.
  let(:dotrspec_tracer) do
    <<~CONFIG
      RSpecTracer.configure do
        remote_cache_backend :s3,
                             bucket: ENV.fetch('RSPEC_TRACER_TEST_BUCKET'),
                             prefix: 'rake-spec',
                             local: true
        upload_non_ci_reports true
      end
    CONFIG
  end

  def run_in_tmpdir
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Rakefile'), user_rakefile)
      File.write(File.join(dir, '.rspec-tracer'), dotrspec_tracer)
      # Initialize git so UserTasks.git_repo? returns true and
      # GitAncestry can compute branch refs (uses HEAD + a single
      # commit so `git rev-list --max-count=25 HEAD` resolves).
      Dir.chdir(dir) do
        system('git', 'init', '-q', '-b', 'main') || raise('git init failed')
        system('git', 'config', 'user.email', 'rspec-tracer-rake-spec@example.com') || raise
        system('git', 'config', 'user.name', 'rspec-tracer rake spec') || raise
        File.write('seed.txt', 'seed')
        system('git', 'add', 'seed.txt') || raise
        system('git', 'commit', '-q', '-m', 'seed') || raise
      end

      # Seed a small cache for upload to consume.
      cache_dir = File.join(dir, 'rspec_tracer_cache')
      FileUtils.mkdir_p(cache_dir)
      File.write(
        File.join(cache_dir, 'last_run.json'),
        JSON.pretty_generate('schema_version' => RSpecTracer::Storage::Schema::CURRENT,
                             'run_id' => 'rake-run', 'timestamp' => Time.now.utc.iso8601)
      )
      FileUtils.mkdir_p(File.join(cache_dir, 'rake-run'))
      File.write(
        File.join(cache_dir, 'rake-run', 'all_examples.json'),
        JSON.pretty_generate('examples' => { 'ex-rake-1' => 'passed' })
      )

      yield(dir)
    end
  end

  def run_rake(task:, dir:, extra_env: {})
    Bundler.with_unbundled_env do
      env = {
        'BUNDLE_GEMFILE' => gemfile_path,
        'RSPEC_TRACER_LOG_LEVEL' => 'info',
        'CI' => 'true',
        'GIT_DEFAULT_BRANCH' => 'main',
        'GIT_BRANCH' => 'main',
        'RSPEC_TRACER_TEST_BUCKET' => @bucket,
        'AWS_ACCESS_KEY_ID' => 'test',
        'AWS_SECRET_ACCESS_KEY' => 'test',
        'AWS_DEFAULT_REGION' => 'us-east-1'
      }.merge(extra_env)
      out, status = Open3.capture2e(env, 'bundle', 'exec', 'rake', task, chdir: dir)
      [out.dup.force_encoding('UTF-8'), status]
    end
  end

  describe 'rspec_tracer:remote_cache:upload' do
    it 'uploads the seeded cache to s3 via the rake-task surface' do
      run_in_tmpdir do |dir|
        out, status = run_rake(task: 'rspec_tracer:remote_cache:upload', dir: dir)

        expect(status.success?).to(be(true), "upload rake task failed:\n#{out}")
        ls_out, ls_err, ls_status = Open3.capture3('awslocal', 's3', 'ls', "s3://#{@bucket}/rake-spec/", '--recursive')
        expect(ls_status.success?).to(be(true), "awslocal s3 ls failed (bucket=#{@bucket}):\nstdout=#{ls_out}\nstderr=#{ls_err}\nrake-output=\n#{out}")
        expect(ls_out).to(match(/cache\.tar\.gz$/), "expected cache archive under bucket #{@bucket}/rake-spec/; got:\n#{ls_out}\nrake-output=\n#{out}")
      end
    end
  end

  describe 'rspec_tracer:remote_cache:download' do
    it 'downloads a previously-uploaded cache via the rake-task surface' do
      run_in_tmpdir do |dir|
        # First, upload from this dir so a cache exists for the matching ref.
        upload_out, upload_status = run_rake(task: 'rspec_tracer:remote_cache:upload', dir: dir)
        raise "seed upload failed:\n#{upload_out}" unless upload_status.success?

        # Wipe local cache and re-download via the rake task.
        FileUtils.rm_rf(File.join(dir, 'rspec_tracer_cache'))

        out, status = run_rake(task: 'rspec_tracer:remote_cache:download', dir: dir)

        expect(status.success?).to(be(true), "download rake task failed:\n#{out}")
        manifest_path = File.join(dir, 'rspec_tracer_cache', 'last_run.json')
        expect(File).to(exist(manifest_path), "expected restored manifest at #{manifest_path}")
        manifest = JSON.parse(File.read(manifest_path))
        expect(manifest['run_id']).to eq('rake-run')
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/InstanceVariable
# rubocop:enable RSpec/LeakyConstantDeclaration, RSpec/ExampleLength, RSpec/MultipleExpectations
# rubocop:enable Lint/ConstantDefinitionInBlock
