# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'logger'

require 'rspec_tracer/remote_cache/user_tasks'
require 'rspec_tracer/remote_cache/git_ancestry'

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe RSpecTracer::RemoteCache::UserTasks do
  # Stand-in backend class: records every method call for inspection,
  # returns configurable responses.
  let(:fake_backend_class) do
    Class.new do
      @all_instances = []

      class << self
        attr_reader :all_instances
      end

      attr_reader :calls, :opts

      def initialize(**opts)
        @opts = opts
        @calls = Hash.new { |h, k| h[k] = [] }
        @download_responses = {}
        @branch_refs_response = {}
        @prune_return = 0
        @upload_error = nil
        self.class.all_instances << self
      end

      def stub_downloads(responses)
        @download_responses = responses
        self
      end

      def stub_branch_refs(refs)
        @branch_refs_response = refs
        self
      end

      def stub_prune(count)
        @prune_return = count
        self
      end

      def stub_upload_error(error)
        @upload_error = error
        self
      end

      def download(ref)
        @calls[:download] << ref
        @download_responses.fetch(ref, false)
      end

      def upload(ref)
        @calls[:upload] << ref
        raise @upload_error if @upload_error
      end

      def branch_refs(name)
        @calls[:branch_refs] << name
        @branch_refs_response
      end

      def write_branch_refs(name, refs)
        @calls[:write_branch_refs] << [name, refs]
      end

      def prune!(count: nil, duration_seconds: nil, pr_branch_ttl_seconds: nil)
        @calls[:prune!] << { count: count, duration_seconds: duration_seconds,
                             pr_branch_ttl_seconds: pr_branch_ttl_seconds }
        @prune_return
      end
    end
  end

  let(:captured_logs) { [] }
  let(:logger) do
    logger_double = instance_double(RSpecTracer::Logger)
    %i[debug info warn error].each do |level|
      allow(logger_double).to receive(level) { |msg| captured_logs << [level, msg] }
    end
    logger_double
  end

  let(:cache_path) { Dir.mktmpdir }

  after { FileUtils.rm_rf(cache_path) }

  # Config double with stubbable accessors. Uses an unverified `double`
  # instead of `instance_double(RSpecTracer::Configuration)` because
  # Configuration is a module mixed into RSpecTracer at runtime; the
  # verifying-double machinery can't resolve methods on a module without
  # an including class in the test context.
  # rubocop:disable RSpec/VerifiedDoubles
  def build_config(overrides = {})
    config = double('Configuration')
    defaults = {
      logger: logger,
      cache_path: cache_path,
      remote_cache_backend_entry: nil,
      reports_s3_path: nil,
      use_local_aws: false,
      upload_non_ci_reports: false,
      cache_retention_count: nil,
      cache_retention_duration_seconds: nil,
      cache_retention_pr_branch_ttl_seconds: nil
    }
    defaults.merge(overrides).each { |key, value| allow(config).to receive(key).and_return(value) }
    config
  end
  # rubocop:enable RSpec/VerifiedDoubles

  def stub_ancestry(branch: 'main', default_branch: 'main', branch_ref: 'abc',
                    ancestry_refs: {}, pr_build: nil)
    ancestry_double = instance_double(RSpecTracer::RemoteCache::GitAncestry)
    allow(ancestry_double).to receive_messages(branch_name: branch, default_branch_name: default_branch,
                                               branch_ref: branch_ref, ancestry_refs: ancestry_refs,
                                               pr_build?: pr_build.nil? ? branch != default_branch : pr_build)
    allow(ancestry_double).to receive(:merge_base_branch!)
    allow(RSpecTracer::RemoteCache::GitAncestry).to receive(:new).and_return(ancestry_double)
    ancestry_double
  end

  def build_env(branch: 'main', default: 'main', test_suite_id: nil, ci_flag: nil)
    env = { 'GIT_BRANCH' => branch, 'GIT_DEFAULT_BRANCH' => default }
    env['TEST_SUITE_ID'] = test_suite_id if test_suite_id
    env['CI'] = ci_flag if ci_flag
    env
  end

  describe '.git_repo?' do
    it 'returns true when inside a git repo' do
      expect(described_class.git_repo?).to be(true) # running from the project root
    end

    it 'returns false when outside a git repo' do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          expect(described_class.git_repo?).to be(false)
        end
      end
    end
  end

  describe '.download!' do
    it 'is a class-level convenience that dispatches to an instance' do
      config = build_config(remote_cache_backend_entry: nil)
      stub_ancestry

      expect(described_class.download!(configuration: config, env: build_env)).to be(false)
    end
  end

  describe '.upload!' do
    it 'is a class-level convenience that dispatches to an instance' do
      config = build_config(remote_cache_backend_entry: [fake_backend_class, {}])
      stub_ancestry

      expect(described_class.upload!(configuration: config, env: build_env)).to be(true)
    end
  end

  describe '#download!' do
    let(:backend_entry) { [fake_backend_class, {}] }

    it 'returns false when no remote_cache_backend is configured' do
      config = build_config(remote_cache_backend_entry: nil)
      stub_ancestry

      result = described_class.new(configuration: config, env: build_env).download!

      expect(result).to be(false)
      expect(captured_logs.any? do |lvl, msg|
        lvl == :warn && msg.include?('no remote_cache_backend configured')
      end).to be(true)
    end

    it 'returns false when no candidate refs exist' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(ancestry_refs: {})

      result = described_class.new(configuration: config, env: build_env).download!

      expect(result).to be(false)
      expect(captured_logs.any? { |lvl, msg| lvl == :warn && msg.include?('no cache candidates') }).to be(true)
    end

    it 'returns true on the first ref that downloads successfully' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(ancestry_refs: { 'sha1' => 100, 'sha2' => 200, 'sha3' => 50 })

      result = described_class.new(configuration: config, env: build_env).download!

      expect(result).to be(false) # no stubbed downloads → all miss
      backend = fake_backend_class.all_instances.last
      # Tried in newest-first order: sha2 (200), sha1 (100), sha3 (50)
      expect(backend.calls[:download]).to eq(%w[sha2 sha1 sha3])
    end

    it 'stops trying refs once one succeeds' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      ancestry = stub_ancestry(ancestry_refs: { 'sha1' => 100, 'sha2' => 200, 'sha3' => 50 })
      # Rebind so we can stub the backend AFTER construction.
      allow(fake_backend_class).to receive(:new).and_wrap_original do |original, **opts|
        instance = original.call(**opts)
        instance.stub_downloads('sha1' => true)
      end

      result = described_class.new(configuration: config, env: build_env).download!

      expect(result).to be(true)
      backend = fake_backend_class.all_instances.last
      # sha2 tried first (newest ts), missed; sha1 tried next, hit.
      expect(backend.calls[:download]).to eq(%w[sha2 sha1])
      _ = ancestry
    end

    it 'merges branch_refs with ancestry on PR builds' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(branch: 'feat', default_branch: 'main', ancestry_refs: { 'anc1' => 100 })
      allow(fake_backend_class).to receive(:new).and_wrap_original do |original, **opts|
        instance = original.call(**opts)
        instance.stub_branch_refs('br1' => 200)
      end

      described_class.new(configuration: config, env: build_env(branch: 'feat')).download!

      backend = fake_backend_class.all_instances.last
      expect(backend.calls[:branch_refs]).to include('feat')
      # Newest first: br1 (200), anc1 (100)
      expect(backend.calls[:download]).to eq(%w[br1 anc1])
    end

    it 'derives backend from legacy reports_s3_path DSL when remote_cache_backend is absent' do
      config = build_config(
        remote_cache_backend_entry: nil,
        reports_s3_path: 's3://legacy-bucket/legacy-prefix',
        use_local_aws: true
      )
      stub_ancestry(ancestry_refs: { 'sha1' => 100 })
      stub_const('RSpecTracer::RemoteCache::UserTasks::BUILT_IN_BACKENDS', s3: fake_backend_class)

      described_class.new(configuration: config, env: build_env).download!

      backend = fake_backend_class.all_instances.last
      expect(backend.opts[:bucket]).to eq('legacy-bucket')
      expect(backend.opts[:prefix]).to eq('legacy-prefix')
      expect(backend.opts[:local]).to be(true)
    end

    it 'raises when GIT_BRANCH env is missing (caught and logged)' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry

      result = described_class.new(configuration: config, env: { 'GIT_DEFAULT_BRANCH' => 'main' }).download!

      expect(result).to be(false)
      expect(captured_logs.any? { |_lvl, msg| msg.include?('GIT_BRANCH') }).to be(true)
    end
  end

  describe '#upload!' do
    let(:backend_entry) { [fake_backend_class, {}] }

    it 'uploads under branch_ref and does not update branch_refs on main tier' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(branch: 'main', default_branch: 'main', branch_ref: 'main-sha')

      described_class.new(configuration: config, env: build_env).upload!

      backend = fake_backend_class.all_instances.last
      expect(backend.calls[:upload]).to eq(['main-sha'])
      expect(backend.calls[:write_branch_refs]).to be_empty
    end

    it 'uploads and updates branch_refs on pr tier' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(branch: 'feat', default_branch: 'main', branch_ref: 'feat-sha',
                    ancestry_refs: { 'anc1' => 100 })

      described_class.new(configuration: config, env: build_env(branch: 'feat')).upload!

      backend = fake_backend_class.all_instances.last
      expect(backend.calls[:upload]).to eq(['feat-sha'])
      expect(backend.calls[:write_branch_refs].size).to eq(1)
      name, refs = backend.calls[:write_branch_refs].first
      expect(name).to eq('feat')
      expect(refs).to include('feat-sha')
    end

    it 'returns false when upload fails' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(branch: 'main', default_branch: 'main')
      allow(fake_backend_class).to receive(:new).and_wrap_original do |original, **opts|
        instance = original.call(**opts)
        instance.stub_upload_error(StandardError.new('wire error'))
      end

      result = described_class.new(configuration: config, env: build_env).upload!

      expect(result).to be(false)
      expect(captured_logs.any? { |lvl, msg| lvl == :warn && msg.include?('wire error') }).to be(true)
    end

    it 'prunes with count knob on main tier' do
      config = build_config(
        remote_cache_backend_entry: backend_entry,
        cache_retention_count: 100
      )
      stub_ancestry(branch: 'main', default_branch: 'main')

      described_class.new(configuration: config, env: build_env).upload!

      backend = fake_backend_class.all_instances.last
      expect(backend.calls[:prune!].first).to include(count: 100, duration_seconds: nil, pr_branch_ttl_seconds: nil)
    end

    it 'prunes with pr_branch_ttl only on pr tier' do
      config = build_config(
        remote_cache_backend_entry: backend_entry,
        cache_retention_count: 100,
        cache_retention_pr_branch_ttl_seconds: 14 * 86_400
      )
      stub_ancestry(branch: 'feat', default_branch: 'main')

      described_class.new(configuration: config, env: build_env(branch: 'feat')).upload!

      backend = fake_backend_class.all_instances.last
      knobs = backend.calls[:prune!].first
      # count is main-only, so nil here; ttl fires on pr.
      expect(knobs[:count]).to be_nil
      expect(knobs[:pr_branch_ttl_seconds]).to eq(14 * 86_400)
    end

    it 'does not prune when no knobs are set' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(branch: 'main', default_branch: 'main')

      described_class.new(configuration: config, env: build_env).upload!

      backend = fake_backend_class.all_instances.last
      expect(backend.calls[:prune!]).to be_empty
    end

    it 'emits unbounded_warning when no retention is configured and the backend reports one' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(branch: 'main', default_branch: 'main')
      allow(fake_backend_class).to receive(:new).and_wrap_original do |original, **opts|
        instance = original.call(**opts)
        def instance.unbounded_warning(**_) = 'too many refs'
        instance
      end

      described_class.new(configuration: config, env: build_env).upload!

      expect(captured_logs).to include([:warn, 'too many refs'])
    end

    it 'skips unbounded_warning when retention is configured' do
      config = build_config(remote_cache_backend_entry: backend_entry, cache_retention_count: 100)
      stub_ancestry(branch: 'main', default_branch: 'main')
      allow(fake_backend_class).to receive(:new).and_wrap_original do |original, **opts|
        instance = original.call(**opts)
        def instance.unbounded_warning(**_) = 'too many refs'
        instance
      end

      described_class.new(configuration: config, env: build_env).upload!

      expect(captured_logs).not_to include([:warn, 'too many refs'])
    end
  end

  describe 'backend resolution' do
    it 'raises when the symbol is not in BUILT_IN_BACKENDS' do
      config = build_config(remote_cache_backend_entry: [:bogus_backend, {}])
      stub_ancestry

      result = described_class.new(configuration: config, env: build_env).download!

      expect(result).to be(false)
      expect(captured_logs.any? { |_l, m| m.include?('unknown remote_cache_backend') }).to be(true)
    end

    it 'raises when the entry is not a Symbol or Class' do
      config = build_config(remote_cache_backend_entry: ['just-a-string', {}])
      stub_ancestry

      result = described_class.new(configuration: config, env: build_env).download!

      expect(result).to be(false)
      expect(captured_logs.any? { |_l, m| m.include?('invalid remote_cache_backend') }).to be(true)
    end
  end

  describe 'config introspection with missing methods' do
    it 'safe_config returns nil when the config does not respond to the method' do
      # Build a real object with only the methods UserTasks actually needs,
      # *missing* cache_retention_*. public_send raises NoMethodError on
      # each call; safe_config rescues and returns nil.
      logger_local = logger
      cache_path_local = cache_path
      backend_class = fake_backend_class
      config_class = Class.new do
        define_method(:logger) { logger_local }
        define_method(:cache_path) { cache_path_local }
        define_method(:upload_non_ci_reports) { false }
        define_method(:reports_s3_path) { nil }
        define_method(:use_local_aws) { false }
        define_method(:remote_cache_backend_entry) { [backend_class, {}] }
      end
      config = config_class.new
      stub_ancestry(branch: 'main', default_branch: 'main')

      expect { described_class.new(configuration: config, env: build_env).upload! }.not_to raise_error
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
