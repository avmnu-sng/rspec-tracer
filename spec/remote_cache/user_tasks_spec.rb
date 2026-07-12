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

      def download(ref, tree_sha: nil)
        @calls[:download] << ref
        @calls[:download_tree_sha] << tree_sha
        @download_responses.fetch(ref, false)
      end

      def upload(ref, tree_sha: nil)
        @calls[:upload] << ref
        @calls[:upload_tree_sha] << tree_sha
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

      def prune_all!(pr_branch_ttl_seconds: nil)
        @calls[:prune_all!] << { pr_branch_ttl_seconds: pr_branch_ttl_seconds }
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
      reports_s3_path_set?: false,
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

  # Missing GIT_DEFAULT_BRANCH degrades gracefully (per the
  # `Never propagate storage errors` contract) - the remote-cache
  # rake-task surface returns false + logs a clear, actionable
  # message at warn level, rather than letting the require_env raise
  # propagate up into `bundle exec rake` as a non-zero exit. The user
  # sees the env-name in the log line and knows what to fix.
  describe 'missing GIT_DEFAULT_BRANCH' do
    let(:config) { build_config(remote_cache_backend_entry: [fake_backend_class, {}]) }

    def warn_messages
      captured_logs.select { |(level, _)| level == :warn }.map(&:last)
    end

    it 'returns false + logs a clear warn when #download! is called without GIT_DEFAULT_BRANCH' do
      runner = described_class.new(configuration: config, env: { 'GIT_BRANCH' => 'feat-1' })

      expect(runner.download!).to be(false)
      expect(warn_messages).to include(
        a_string_including('download failed').and(a_string_including('GIT_DEFAULT_BRANCH'))
      )
    end

    it 'treats GIT_DEFAULT_BRANCH=empty the same as unset' do
      runner = described_class.new(
        configuration: config,
        env: { 'GIT_DEFAULT_BRANCH' => '', 'GIT_BRANCH' => 'feat-1' }
      )

      expect(runner.download!).to be(false)
      expect(warn_messages).to include(a_string_including('GIT_DEFAULT_BRANCH'))
    end

    it 'returns false + logs a clear warn from #upload! (consistent UX across both rake tasks)' do
      runner = described_class.new(configuration: config, env: { 'GIT_BRANCH' => 'main' })

      expect(runner.upload!).to be(false)
      expect(warn_messages).to include(
        a_string_including('upload failed').and(a_string_including('GIT_DEFAULT_BRANCH'))
      )
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

    it 'emits an INFO log line naming the ref on a successful main-tier download' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(branch: 'main', default_branch: 'main', ancestry_refs: { 'main-sha' => 100 })
      allow(fake_backend_class).to receive(:new).and_wrap_original do |original, **opts|
        instance = original.call(**opts)
        instance.stub_downloads('main-sha' => true)
      end

      described_class.new(configuration: config, env: build_env).download!

      info_messages = captured_logs.select { |(level, _)| level == :info }.map(&:last)
      expect(info_messages).to include('rspec-tracer remote_cache: restored cache from main-sha')
    end

    it 'qualifies the INFO log with "(cross-branch fallback)" when a PR build hits an ancestry ref' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      # PR build with NO branch_refs (so a hit goes through the ancestry path).
      stub_ancestry(branch: 'feat', default_branch: 'main', ancestry_refs: { 'main-sha' => 100 })
      allow(fake_backend_class).to receive(:new).and_wrap_original do |original, **opts|
        instance = original.call(**opts)
        instance.stub_branch_refs({}).stub_downloads('main-sha' => true)
      end

      described_class.new(configuration: config, env: build_env(branch: 'feat')).download!

      info_messages = captured_logs.select { |(level, _)| level == :info }.map(&:last)
      expect(info_messages).to include(
        'rspec-tracer remote_cache: restored cache from main-sha (cross-branch fallback)'
      )
    end

    it 'omits the cross-branch qualifier when a PR build hits its own branch_refs' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(branch: 'feat', default_branch: 'main', ancestry_refs: { 'anc1' => 100 })
      allow(fake_backend_class).to receive(:new).and_wrap_original do |original, **opts|
        instance = original.call(**opts)
        # br1 has the newest ts so it's tried first and hits — PR-tier (branch_refs) origin.
        instance.stub_branch_refs('br1' => 200).stub_downloads('br1' => true)
      end

      described_class.new(configuration: config, env: build_env(branch: 'feat')).download!

      info_messages = captured_logs.select { |(level, _)| level == :info }.map(&:last)
      expect(info_messages).to include('rspec-tracer remote_cache: restored cache from br1')
      expect(info_messages).not_to(include(a_string_including('cross-branch fallback')))
    end

    it 'does not probe the deprecated reports_s3_path when reports_s3_path_set? is false' do
      config = build_config(remote_cache_backend_entry: nil, reports_s3_path_set?: false)
      stub_ancestry

      described_class.new(configuration: config, env: build_env).download!

      expect(config).not_to have_received(:reports_s3_path)
    end

    it 'returns nil from the legacy probe when the getter yields a nil/empty value' do
      # Edge case: reports_s3_path_set? returns true (env was set), but the
      # getter returns nil (the env value failed valid_s3_path? in Configuration
      # and never populated @reports_s3_path). The probe defensively bails out.
      config = build_config(
        remote_cache_backend_entry: nil,
        reports_s3_path: nil,
        reports_s3_path_set?: true
      )
      stub_ancestry

      result = described_class.new(configuration: config, env: build_env).download!

      expect(result).to be(false)
      warns = captured_logs.select { |(level, _)| level == :warn }.map(&:last)
      expect(warns).to include(a_string_including('no remote_cache_backend configured'))
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
        reports_s3_path_set?: true,
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

    it 'rejects a legacy reports_s3_path with a non-s3 scheme (returns nil → unconfigured)' do
      config = build_config(
        remote_cache_backend_entry: nil,
        reports_s3_path: 'http://example.com/cache',
        reports_s3_path_set?: true
      )
      stub_ancestry

      result = described_class.new(configuration: config, env: build_env).download!

      expect(result).to be(false)
      expect(captured_logs.any? do |lvl, msg|
        lvl == :warn && msg.include?('no remote_cache_backend configured')
      end).to be(true)
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

    it 'emits an INFO log line naming the ref on successful upload' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(branch: 'main', default_branch: 'main', branch_ref: 'main-sha')

      described_class.new(configuration: config, env: build_env).upload!

      info_messages = captured_logs.select { |(level, _)| level == :info }.map(&:last)
      expect(info_messages).to include('rspec-tracer remote_cache: uploaded cache to main-sha')
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

    it 'skips prune entirely when the backend does not implement prune!' do
      backend_class_without_prune = Class.new do
        attr_reader :calls

        def initialize(**)
          @calls = Hash.new { |h, k| h[k] = [] }
        end

        def upload(_ref, **) = nil
        def branch_refs(_name) = {}
        def write_branch_refs(_name, _refs) = nil
      end

      config = build_config(
        remote_cache_backend_entry: [backend_class_without_prune, {}],
        cache_retention_count: 100
      )
      stub_ancestry(branch: 'main', default_branch: 'main')

      expect do
        described_class.new(configuration: config, env: build_env).upload!
      end.not_to raise_error
    end

    it 'logs the pruned-refs count when prune! returns a positive integer' do
      config = build_config(
        remote_cache_backend_entry: backend_entry,
        cache_retention_count: 100
      )
      stub_ancestry(branch: 'main', default_branch: 'main')
      allow(fake_backend_class).to receive(:new).and_wrap_original do |original, **opts|
        original.call(**opts).stub_prune(7)
      end

      described_class.new(configuration: config, env: build_env).upload!

      expect(captured_logs.any? { |lvl, msg| lvl == :debug && msg.include?('pruned 7 refs') }).to be(true)
    end

    it 'prunes with duration_seconds knob and skips the unbounded warning on main tier' do
      config = build_config(
        remote_cache_backend_entry: backend_entry,
        cache_retention_duration_seconds: 7 * 86_400
      )
      stub_ancestry(branch: 'main', default_branch: 'main')
      allow(fake_backend_class).to receive(:new).and_wrap_original do |original, **opts|
        instance = original.call(**opts)
        def instance.unbounded_warning(**_) = 'too many refs'
        instance
      end

      described_class.new(configuration: config, env: build_env).upload!

      backend = fake_backend_class.all_instances.last
      expect(backend.calls[:prune!].first).to include(duration_seconds: 7 * 86_400)
      expect(captured_logs).not_to include([:warn, 'too many refs'])
    end

    it 'skips logger.warn when the backend reports no unbounded_warning (nil reply)' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(branch: 'main', default_branch: 'main')
      allow(fake_backend_class).to receive(:new).and_wrap_original do |original, **opts|
        instance = original.call(**opts)
        def instance.unbounded_warning(**_) = nil
        instance
      end

      described_class.new(configuration: config, env: build_env).upload!

      expect(captured_logs.none? { |lvl, _msg| lvl == :warn }).to be(true)
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

  describe '#head_tree_sha (private)' do
    let(:tasks) do
      config = build_config(remote_cache_backend_entry: nil)
      described_class.new(configuration: config, env: build_env)
    end

    it 'resolves the HEAD tree SHA in the project git repo' do
      sha = tasks.send(:head_tree_sha)

      expect(sha).to match(/\A[0-9a-f]{40}\z/)
    end

    it 'returns nil outside a git repo (graceful nil contract)' do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          expect(tasks.send(:head_tree_sha)).to be_nil
        end
      end
    end

    it 'returns nil when the git binary raises (StandardError rescue)' do
      allow(tasks).to receive(:`).and_raise(Errno::ENOENT, 'No such file or directory')

      expect(tasks.send(:head_tree_sha)).to be_nil
    end

    it 'returns nil when $CHILD_STATUS is nil (no subprocess yet on this thread)' do
      # `$CHILD_STATUS` is thread-local; a fresh Ruby thread that has not
      # yet spawned a subprocess sees `$?` as nil. Combined with a stubbed
      # backtick that bypasses the subprocess fork entirely, this exercises
      # the safe-nav else branch in `$CHILD_STATUS&.success?`.
      result = Thread.new do
        allow(tasks).to receive(:`).and_return('tree-sha-output')
        tasks.send(:head_tree_sha)
      end.value

      expect(result).to be_nil
    end

    it 'returns nil when git rev-parse succeeds but emits empty output' do
      allow(tasks).to receive(:`).and_return("\n")

      # A successful subprocess elsewhere in this thread set `$?` to a
      # success status; chomp("\n") -> "" -> output.empty? branch fires.
      `true`
      expect(tasks.send(:head_tree_sha)).to be_nil
    end
  end

  describe 'tree_sha forwarding' do
    let(:backend_entry) { [fake_backend_class, {}] }

    it 'forwards the resolved tree_sha through to backend.upload on PR build' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(branch: 'feat', default_branch: 'main', branch_ref: 'feat-sha',
                    ancestry_refs: { 'anc1' => 100 })
      tasks = described_class.new(configuration: config, env: build_env(branch: 'feat'))
      allow(tasks).to receive(:head_tree_sha).and_return('tree-sha-abc123')

      tasks.upload!

      backend = fake_backend_class.all_instances.last
      expect(backend.calls[:upload_tree_sha]).to eq(['tree-sha-abc123'])
    end

    it 'forwards the resolved tree_sha through to every backend.download attempt' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(ancestry_refs: { 'sha1' => 100, 'sha2' => 200 })
      tasks = described_class.new(configuration: config, env: build_env)
      allow(tasks).to receive(:head_tree_sha).and_return('tree-sha-xyz789')

      tasks.download!

      backend = fake_backend_class.all_instances.last
      expect(backend.calls[:download_tree_sha]).to eq(%w[tree-sha-xyz789 tree-sha-xyz789])
    end

    it 'forwards nil when head_tree_sha is unavailable (graceful nil contract)' do
      config = build_config(remote_cache_backend_entry: backend_entry)
      stub_ancestry(branch: 'main', default_branch: 'main', branch_ref: 'main-sha')
      tasks = described_class.new(configuration: config, env: build_env)
      allow(tasks).to receive(:head_tree_sha).and_return(nil)

      tasks.upload!

      backend = fake_backend_class.all_instances.last
      expect(backend.calls[:upload_tree_sha]).to eq([nil])
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

    it 'resolves :local_fs to LocalFsBackend' do
      expect(described_class::BUILT_IN_BACKENDS[:local_fs]).to eq(RSpecTracer::RemoteCache::LocalFsBackend)
    end

    it 'resolves :redis to RedisBackend' do
      expect(described_class::BUILT_IN_BACKENDS[:redis]).to eq(RSpecTracer::RemoteCache::RedisBackend)
    end
  end

  describe '#prune_all!' do
    let(:backend_entry) { [fake_backend_class, {}] }

    it 'returns 0 when cache_retention_pr_branch_ttl_seconds is unset' do
      config = build_config(remote_cache_backend_entry: backend_entry,
                            cache_retention_pr_branch_ttl_seconds: nil)
      stub_ancestry

      result = described_class.new(configuration: config, env: build_env).prune_all!

      expect(result).to eq(0)
      expect(captured_logs.any? { |_l, m| m.include?('prune_all requires cache_retention_pr_branch_ttl') }).to be(true)
    end

    it 'dispatches to backend.prune_all! with the configured ttl when set' do
      config = build_config(remote_cache_backend_entry: backend_entry,
                            cache_retention_pr_branch_ttl_seconds: 7200)
      stub_ancestry

      tasks = described_class.new(configuration: config, env: build_env)
      allow_any_instance_of(fake_backend_class).to receive(:prune_all!).and_return(5) # rubocop:disable RSpec/AnyInstance

      expect(tasks.prune_all!).to eq(5)
    end

    it 'emits an INFO log line with the removed count on a successful run' do
      config = build_config(remote_cache_backend_entry: backend_entry,
                            cache_retention_pr_branch_ttl_seconds: 7200)
      stub_ancestry
      tasks = described_class.new(configuration: config, env: build_env)
      allow_any_instance_of(fake_backend_class).to receive(:prune_all!).and_return(3) # rubocop:disable RSpec/AnyInstance

      tasks.prune_all!

      info_messages = captured_logs.select { |(level, _)| level == :info }.map(&:last)
      expect(info_messages).to include('rspec-tracer remote_cache: prune_all removed 3 refs')
    end

    it 'returns 0 and logs on StandardError from the backend' do
      config = build_config(remote_cache_backend_entry: backend_entry,
                            cache_retention_pr_branch_ttl_seconds: 3600)
      stub_ancestry
      allow_any_instance_of(fake_backend_class).to receive(:prune_all!).and_raise(RuntimeError, 'boom') # rubocop:disable RSpec/AnyInstance

      result = described_class.new(configuration: config, env: build_env).prune_all!

      expect(result).to eq(0)
      expect(captured_logs.any? { |_l, m| m.include?('prune_all failed') }).to be(true)
    end

    it 'allows GIT_BRANCH to be unset and defaults it to GIT_DEFAULT_BRANCH' do
      config = build_config(remote_cache_backend_entry: backend_entry,
                            cache_retention_pr_branch_ttl_seconds: 3600)
      stub_ancestry

      env = { 'GIT_DEFAULT_BRANCH' => 'main' } # GIT_BRANCH intentionally omitted

      expect { described_class.new(configuration: config, env: env).prune_all! }.not_to raise_error
    end

    it 'requires GIT_DEFAULT_BRANCH to be set (graceful failure logs)' do
      config = build_config(remote_cache_backend_entry: backend_entry,
                            cache_retention_pr_branch_ttl_seconds: 3600)

      env = {} # both GIT_BRANCH and GIT_DEFAULT_BRANCH omitted

      result = described_class.new(configuration: config, env: env).prune_all!

      expect(result).to eq(0)
      expect(captured_logs.any? do |_l, m|
        m.include?('prune_all failed') && m.include?('GIT_DEFAULT_BRANCH')
      end).to be(true)
    end
  end

  describe '.prune_all!' do
    it 'is a class-level convenience that dispatches to an instance' do
      config = build_config(remote_cache_backend_entry: [fake_backend_class, {}],
                            cache_retention_pr_branch_ttl_seconds: nil)
      stub_ancestry

      expect(described_class.prune_all!(configuration: config, env: build_env)).to eq(0)
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
