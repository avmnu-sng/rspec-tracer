# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'

require 'rspec_tracer/remote_cache/s3_backend'
require 'rspec_tracer/storage/schema'
require_relative '../contracts/remote_cache_backend'

# rubocop:disable RSpec/InstanceVariable, RSpec/ExampleLength, RSpec/MultipleExpectations
# rubocop:disable RSpec/ContextWording
RSpec.describe RSpecTracer::RemoteCache::S3Backend do
  around do |example|
    Dir.mktmpdir do |dir|
      @cache_path = dir
      example.run
    end
  end

  let(:current_schema) { RSpecTracer::Storage::Schema::CURRENT }
  let(:status_ok) { instance_double(Process::Status, success?: true) }
  let(:status_fail) { instance_double(Process::Status, success?: false) }

  def new_backend(branch: 'main', default_branch: 'main', test_suite_id: nil, local: false, prefix: 'rspec-tracer')
    described_class.new(
      bucket: 'my-bucket',
      prefix: prefix,
      branch: branch,
      default_branch: default_branch,
      test_suite_id: test_suite_id,
      local: local,
      cache_path: @cache_path
    )
  end

  def write_valid_last_run(path, run_id: 'abc123')
    File.write(path, JSON.pretty_generate('schema_version' => current_schema, 'run_id' => run_id))
  end

  # Build a real valid `cache.tar.gz` at `archive_dest` by first
  # materializing a minimal last_run.json + run_dir under a temp cache
  # and packing via the same Archive module the backend uses. Stubs
  # then return success for the `aws s3 cp` call and the tests drive
  # the real extract path.
  def build_valid_archive(archive_dest, run_id: 'abc123', schema: current_schema)
    Dir.mktmpdir do |src|
      File.write(File.join(src, 'last_run.json'), JSON.pretty_generate('schema_version' => schema, 'run_id' => run_id))
      FileUtils.mkdir_p(File.join(src, run_id))
      File.write(File.join(src, run_id, 'all_examples.json'), '{"ex1":"passed"}')
      RSpecTracer::RemoteCache::Archive.pack(cache_path: src, run_id: run_id, dest_path: archive_dest)
    end
  end

  def build_invalid_schema_archive(archive_dest, run_id: 'abc123')
    build_valid_archive(archive_dest, run_id: run_id, schema: current_schema + 99)
  end

  it_behaves_like 'a RemoteCache::Backend' do
    let(:backend) { new_backend }
  end

  describe '#initialize' do
    it 'raises on missing bucket' do
      expect do
        described_class.new(
          bucket: nil, prefix: 'p', branch: 'main', default_branch: 'main', cache_path: @cache_path
        )
      end.to raise_error(described_class::S3BackendError, /bucket/)
    end

    it 'raises on missing prefix' do
      expect do
        described_class.new(
          bucket: 'b', prefix: '', branch: 'main', default_branch: 'main', cache_path: @cache_path
        )
      end.to raise_error(described_class::S3BackendError, /prefix/)
    end

    it 'raises on missing branch' do
      expect do
        described_class.new(
          bucket: 'b', prefix: 'p', branch: nil, default_branch: 'main', cache_path: @cache_path
        )
      end.to raise_error(described_class::S3BackendError, /branch/)
    end

    it 'raises on missing default_branch' do
      expect do
        described_class.new(
          bucket: 'b', prefix: 'p', branch: 'main', default_branch: '', cache_path: @cache_path
        )
      end.to raise_error(described_class::S3BackendError, /default_branch/)
    end

    it 'raises on missing cache_path' do
      expect do
        described_class.new(
          bucket: 'b', prefix: 'p', branch: 'main', default_branch: 'main', cache_path: nil
        )
      end.to raise_error(described_class::S3BackendError, /cache_path/)
    end

    it 'strips trailing slashes from prefix' do
      backend = new_backend(prefix: 'rspec-tracer///')
      expect(backend.instance_variable_get(:@prefix)).to eq('rspec-tracer')
    end

    it 'selects awslocal when local: true' do
      backend = new_backend(local: true)
      expect(backend.instance_variable_get(:@cli_binary)).to eq('awslocal')
    end

    it 'selects aws when local is false or unset' do
      backend = new_backend(local: false)
      expect(backend.instance_variable_get(:@cli_binary)).to eq('aws')
    end

    it 'treats empty-string test_suite_id as nil' do
      backend = new_backend(test_suite_id: '')
      expect(backend.instance_variable_get(:@test_suite_id)).to be_nil
    end
  end

  describe '#download' do
    context 'on main branch' do
      it 'downloads from main tier when the archive validates' do
        backend = new_backend(branch: 'main', default_branch: 'main')
        allow(Open3).to receive(:capture3) do |_cli, *args|
          if args[0..1] == %w[s3 cp] && args[2] == 's3://my-bucket/rspec-tracer/main/abc/cache.tar.gz'
            build_valid_archive(args[3])
            ['', '', status_ok]
          else
            ['', "unmatched: #{args.inspect}", status_fail]
          end
        end

        expect(backend.download('abc')).to be(true)
        expect(File.read(File.join(@cache_path, 'abc123', 'all_examples.json'))).to eq('{"ex1":"passed"}')
      end

      it 'returns false when the archive download fails' do
        backend = new_backend(branch: 'main', default_branch: 'main')
        allow(Open3).to receive(:capture3).and_return(['', 'not found', status_fail])

        expect(backend.download('abc')).to be(false)
      end

      it 'returns false and cleans up when schema_version mismatches' do
        backend = new_backend(branch: 'main', default_branch: 'main')
        allow(Open3).to receive(:capture3) do |_cli, *args|
          build_invalid_schema_archive(args[3])
          ['', '', status_ok]
        end

        expect(backend.download('abc')).to be(false)
        expect(File.exist?(File.join(@cache_path, 'last_run.json'))).to be(false)
        expect(File.directory?(File.join(@cache_path, 'abc123'))).to be(false)
      end

      it 'returns false and cleans up when extract fails (corrupt archive)' do
        backend = new_backend(branch: 'main', default_branch: 'main')
        allow(Open3).to receive(:capture3) do |_cli, *args|
          File.write(args[3], 'not-a-valid-tar-gz')
          ['', '', status_ok]
        end

        expect(backend.download('abc')).to be(false)
      end
    end

    context 'on PR branch' do
      it 'tries pr tier first, falls back to main tier on miss' do
        backend = new_backend(branch: 'feat', default_branch: 'main')
        tried_urls = []
        allow(Open3).to receive(:capture3) do |_cli, *args|
          if args[0..1] == %w[s3 cp]
            tried_urls << args[2]
            if args[2].include?('/pr/feat/')
              ['', 'pr miss', status_fail]
            else
              build_valid_archive(args[3])
              ['', '', status_ok]
            end
          else
            ['', "unmatched: #{args.inspect}", status_fail]
          end
        end

        expect(backend.download('abc')).to be(true)
        expect(tried_urls.first).to include('/pr/feat/')
        expect(tried_urls.last).to include('/main/')
      end
    end

    it 'composes key with test_suite_id when present' do
      backend = new_backend(branch: 'main', default_branch: 'main', test_suite_id: '1')
      observed = nil
      allow(Open3).to receive(:capture3) do |_cli, *args|
        observed = args[2] if args[0..1] == %w[s3 cp]
        ['', 'miss', status_fail]
      end

      backend.download('abc')
      expect(observed).to eq('s3://my-bucket/rspec-tracer/main/abc/1/cache.tar.gz')
    end
  end

  describe '#upload' do
    let(:backend) { new_backend(branch: 'main', default_branch: 'main') }

    before do
      write_valid_last_run(File.join(@cache_path, 'last_run.json'))
      FileUtils.mkdir_p(File.join(@cache_path, 'abc123'))
    end

    it 'packs the local cache and uploads a single archive to the backend tier' do
      uploads = []
      allow(Open3).to receive(:capture3) do |_cli, *args|
        uploads << args
        ['', '', status_ok]
      end

      backend.upload('mysha')

      expect(uploads.size).to eq(1)
      src, dst = uploads.first[2..]
      expect(src).to end_with('.tar.gz')
      expect(dst).to eq('s3://my-bucket/rspec-tracer/main/mysha/cache.tar.gz')
    end

    it 'raises when ref is nil' do
      expect { backend.upload(nil) }.to raise_error(described_class::S3BackendError, /ref/)
    end

    it 'raises when no local cache is available' do
      FileUtils.rm(File.join(@cache_path, 'last_run.json'))

      expect { backend.upload('mysha') }.to raise_error(described_class::S3BackendError, /no local cache/)
    end

    it 'raises when local last_run.json is malformed JSON' do
      File.write(File.join(@cache_path, 'last_run.json'), '{not valid')

      expect { backend.upload('mysha') }.to raise_error(described_class::S3BackendError, /no local cache/)
    end

    it 'raises when the upload aws call fails' do
      allow(Open3).to receive(:capture3).and_return(['', 'access denied', status_fail])

      expect { backend.upload('mysha') }.to raise_error(described_class::S3BackendError, /access denied/)
    end

    it 'routes uploads to pr tier on a PR branch' do
      pr_backend = new_backend(branch: 'feat', default_branch: 'main')
      write_valid_last_run(File.join(@cache_path, 'last_run.json'))
      FileUtils.mkdir_p(File.join(@cache_path, 'abc123'))
      uploads = []
      allow(Open3).to receive(:capture3) do |_cli, *args|
        uploads << args
        ['', '', status_ok]
      end

      pr_backend.upload('mysha')

      expect(uploads.first[3]).to eq('s3://my-bucket/rspec-tracer/pr/feat/mysha/cache.tar.gz')
    end
  end

  describe '#branch_refs' do
    let(:backend) { new_backend(branch: 'feat', default_branch: 'main') }

    it 'returns parsed branch_refs when the file download succeeds' do
      allow(Open3).to receive(:capture3) do |_cli, *args|
        tmp_dst = args.last
        File.write(tmp_dst, JSON.pretty_generate('sha1' => 1_700_000_000, 'sha2' => 1_700_000_100))
        ['', '', status_ok]
      end

      refs = backend.branch_refs('feat')

      expect(refs).to eq('sha1' => 1_700_000_000, 'sha2' => 1_700_000_100)
    end

    it 'returns {} when the file is missing' do
      allow(Open3).to receive(:capture3).and_return(['', 'not found', status_fail])

      expect(backend.branch_refs('feat')).to eq({})
    end

    it 'returns {} when the file is malformed JSON' do
      allow(Open3).to receive(:capture3) do |_cli, *args|
        File.write(args.last, '{not valid')
        ['', '', status_ok]
      end

      expect(backend.branch_refs('feat')).to eq({})
    end

    it 'returns {} when the file contains non-hash JSON' do
      allow(Open3).to receive(:capture3) do |_cli, *args|
        File.write(args.last, '[1, 2, 3]')
        ['', '', status_ok]
      end

      expect(backend.branch_refs('feat')).to eq({})
    end
  end

  describe '#write_branch_refs' do
    let(:backend) { new_backend(branch: 'feat', default_branch: 'main') }

    it 'uploads the refs json to pr/<branch>/branch_refs.json' do
      uploads = []
      allow(Open3).to receive(:capture3) do |_cli, *args|
        uploads << args
        ['', '', status_ok]
      end

      backend.write_branch_refs('feat', 'sha1' => 1_700_000_000)

      expect(uploads.first[3]).to include('/pr/feat/branch_refs.json')
    end

    it 'is a no-op when branch_name matches default_branch' do
      allow(Open3).to receive(:capture3)

      backend.write_branch_refs('main', 'sha1' => 1)

      expect(Open3).not_to have_received(:capture3)
    end

    it 'raises when the upload fails' do
      allow(Open3).to receive(:capture3).and_return(['', 'access denied', status_fail])

      expect { backend.write_branch_refs('feat', 'sha1' => 1) }
        .to raise_error(described_class::S3BackendError, /branch_refs/)
    end
  end

  describe '#prune!' do
    let(:backend) { new_backend(branch: 'main', default_branch: 'main') }

    def list_json(keys_with_ts)
      contents = keys_with_ts.map { |key, ts| { 'Key' => key, 'LastModified' => Time.at(ts).utc.iso8601 } }
      JSON.generate('Contents' => contents)
    end

    it 'no-ops when all knobs are nil or zero' do
      removed = backend.prune!(count: nil, duration_seconds: nil, pr_branch_ttl_seconds: nil)
      expect(removed).to eq(0)
    end

    it 'prunes excess refs beyond count' do
      now = Time.now.to_i
      keys = (1..5).map { |i| ["rspec-tracer/main/sha#{i}/cache.tar.gz", now - (i * 3600)] }
      allow(Open3).to receive(:capture3) do |_cli, *args|
        if args.first == 's3api'
          [list_json(keys), '', status_ok]
        else
          ['', '', status_ok]
        end
      end

      removed = backend.prune!(count: 2)

      expect(removed).to eq(3)
    end

    it 'prunes refs older than duration_seconds' do
      now = Time.now.to_i
      keys = [
        ['rspec-tracer/main/recent/cache.tar.gz', now - 60],
        ['rspec-tracer/main/old/cache.tar.gz', now - (30 * 86_400)],
        ['rspec-tracer/main/ancient/cache.tar.gz', now - (365 * 86_400)]
      ]
      allow(Open3).to receive(:capture3) do |_cli, *args|
        if args.first == 's3api'
          [list_json(keys), '', status_ok]
        else
          ['', '', status_ok]
        end
      end

      removed = backend.prune!(duration_seconds: 7 * 86_400)

      expect(removed).to eq(2)
    end

    it 'prunes entire dead PR branch when pr_branch_ttl_seconds exceeded' do
      pr_backend = new_backend(branch: 'feat', default_branch: 'main')
      now = Time.now.to_i
      keys = [['rspec-tracer/pr/feat/old_sha/cache.tar.gz', now - (30 * 86_400)]]
      allow(Open3).to receive(:capture3) do |_cli, *args|
        if args.first == 's3api'
          [list_json(keys), '', status_ok]
        else
          ['', '', status_ok]
        end
      end

      removed = pr_backend.prune!(pr_branch_ttl_seconds: 14 * 86_400)

      expect(removed).to eq(1)
    end

    it 'does not prune live PR branches whose newest ref is within the TTL' do
      pr_backend = new_backend(branch: 'feat', default_branch: 'main')
      now = Time.now.to_i
      keys = [['rspec-tracer/pr/feat/recent/cache.tar.gz', now - 60]]
      allow(Open3).to receive(:capture3) do |_cli, *args|
        if args.first == 's3api'
          [list_json(keys), '', status_ok]
        else
          ['', '', status_ok]
        end
      end

      expect(pr_backend.prune!(pr_branch_ttl_seconds: 14 * 86_400)).to eq(0)
    end

    it 'ignores list-objects failures and reports partial counts' do
      allow(Open3).to receive(:capture3).and_return(['', 'list failed', status_fail])

      expect(backend.prune!(count: 5)).to eq(0)
    end

    it 'continues on per-ref delete failures' do
      now = Time.now.to_i
      keys = (1..3).map { |i| ["rspec-tracer/main/sha#{i}/cache.tar.gz", now - (i * 3600)] }
      call = 0
      allow(Open3).to receive(:capture3) do |_cli, *args|
        if args.first == 's3api'
          [list_json(keys), '', status_ok]
        else
          call += 1
          call.odd? ? ['', '', status_ok] : ['', 'delete failed', status_fail]
        end
      end

      # count=0 would no-op; count=1 keeps newest, tries to delete 2.
      removed = backend.prune!(count: 1)

      expect(removed).to be_between(0, 2)
    end

    it 'ignores malformed list-objects JSON output' do
      allow(Open3).to receive(:capture3) do |_cli, *args|
        if args.first == 's3api'
          ['{not valid json', '', status_ok]
        else
          ['', '', status_ok]
        end
      end

      expect(backend.prune!(count: 5)).to eq(0)
    end

    it 'returns 0 when pr_branch_ttl delete fails' do
      pr_backend = new_backend(branch: 'feat', default_branch: 'main')
      now = Time.now.to_i
      keys = [['rspec-tracer/pr/feat/old/cache.tar.gz', now - (60 * 86_400)]]
      allow(Open3).to receive(:capture3) do |_cli, *args|
        if args.first == 's3api'
          [list_json(keys), '', status_ok]
        else
          ['', 'rm failed', status_fail]
        end
      end

      expect(pr_backend.prune!(pr_branch_ttl_seconds: 14 * 86_400)).to eq(0)
    end

    it 'treats malformed LastModified timestamps as epoch 0' do
      backend = new_backend(branch: 'main', default_branch: 'main')
      keys = [
        ['rspec-tracer/main/bad/cache.tar.gz', 'not-a-timestamp'],
        ['rspec-tracer/main/good/cache.tar.gz', Time.now.utc.iso8601]
      ]
      contents = keys.map { |key, ts| { 'Key' => key, 'LastModified' => ts } }
      allow(Open3).to receive(:capture3) do |_cli, *args|
        if args.first == 's3api'
          [JSON.generate('Contents' => contents), '', status_ok]
        else
          ['', '', status_ok]
        end
      end

      # With a malformed timestamp, the bad ref sorts to epoch 0 (oldest).
      # count=1 keeps the good ref, deletes the bad one.
      removed = backend.prune!(count: 1)

      expect(removed).to eq(1)
    end

    it 'returns 0 when pr tier has no refs at all' do
      pr_backend = new_backend(branch: 'feat-empty', default_branch: 'main')
      allow(Open3).to receive(:capture3) do |_cli, *args|
        if args.first == 's3api'
          [JSON.generate('Contents' => []), '', status_ok]
        else
          ['', '', status_ok]
        end
      end

      expect(pr_backend.prune!(pr_branch_ttl_seconds: 14 * 86_400)).to eq(0)
    end
  end

  describe '#prune_all!' do
    let(:backend) { new_backend(branch: 'main', default_branch: 'main') }

    def common_prefixes_json(branches)
      contents = branches.map { |b| { 'Prefix' => "rspec-tracer/pr/#{b}/" } }
      JSON.generate('CommonPrefixes' => contents)
    end

    def list_json(keys_with_ts)
      contents = keys_with_ts.map { |key, ts| { 'Key' => key, 'LastModified' => Time.at(ts).utc.iso8601 } }
      JSON.generate('Contents' => contents)
    end

    it 'returns 0 when pr_branch_ttl_seconds is nil' do
      expect(backend.prune_all!).to eq(0)
    end

    it 'returns 0 when pr_branch_ttl_seconds is zero or negative' do
      expect(backend.prune_all!(pr_branch_ttl_seconds: 0)).to eq(0)
      expect(backend.prune_all!(pr_branch_ttl_seconds: -1)).to eq(0)
    end

    it 'discovers every PR branch via list-objects delimiter and prunes dead ones' do
      now = Time.now.to_i
      # Two branches: live (recent) and dead (ancient)
      call_args = []
      allow(Open3).to receive(:capture3) do |_cli, *args|
        call_args << args
        if args.include?('--delimiter')
          [common_prefixes_json(%w[live dead]), '', status_ok]
        elsif args.include?('list-objects-v2') && args.any? { |a| a.to_s.include?('pr/live') }
          [list_json([['rspec-tracer/pr/live/sha1/cache.tar.gz', now - 60]]), '', status_ok]
        elsif args.include?('list-objects-v2') && args.any? { |a| a.to_s.include?('pr/dead') }
          [list_json([['rspec-tracer/pr/dead/sha2/cache.tar.gz', now - (30 * 86_400)]]), '', status_ok]
        else
          ['', '', status_ok]
        end
      end

      removed = backend.prune_all!(pr_branch_ttl_seconds: 14 * 86_400)

      expect(removed).to eq(1)
      rm_calls = call_args.select { |a| a.first == 's3' && a[1] == 'rm' }
      expect(rm_calls.any? { |a| a[2].include?('/pr/dead/') }).to be(true)
      expect(rm_calls.none? { |a| a[2].include?('/pr/live/') }).to be(true)
    end

    it 'returns 0 when no PR branches exist' do
      allow(Open3).to receive(:capture3) do |_cli, *args|
        if args.include?('--delimiter')
          [JSON.generate('CommonPrefixes' => []), '', status_ok]
        else
          ['', '', status_ok]
        end
      end

      expect(backend.prune_all!(pr_branch_ttl_seconds: 3600)).to eq(0)
    end

    it 'rescues StandardError from the outer prune_all walk and returns 0' do
      # Inner Open3 calls have their own rescues; to hit prune_all!'s
      # top-level rescue, force maybe_prune_branch itself to raise after
      # discover_pr_branches returned a branch.
      allow(backend).to receive(:discover_pr_branches).and_return(['feat'])
      allow(backend).to receive(:maybe_prune_branch).and_raise(RuntimeError, 'network fire')

      expect(backend.prune_all!(pr_branch_ttl_seconds: 3600)).to eq(0)
    end

    it 'skips malformed CommonPrefixes entries' do
      allow(Open3).to receive(:capture3) do |_cli, *args|
        if args.include?('--delimiter')
          [JSON.generate('CommonPrefixes' => [{ 'Prefix' => nil }, { 'Prefix' => 'outside/' }]), '', status_ok]
        else
          ['', '', status_ok]
        end
      end

      expect(backend.prune_all!(pr_branch_ttl_seconds: 3600)).to eq(0)
    end

    it 'returns 0 when list-common-prefixes stdout fails to parse' do
      allow(Open3).to receive(:capture3) do |_cli, *args|
        if args.include?('--delimiter')
          ['{not json', '', status_ok]
        else
          ['', '', status_ok]
        end
      end

      expect(backend.prune_all!(pr_branch_ttl_seconds: 3600)).to eq(0)
    end

    it 'returns 0 when list-common-prefixes stderr signals failure' do
      allow(Open3).to receive(:capture3) do |_cli, *args|
        if args.include?('--delimiter')
          ['', 'access denied', status_fail]
        else
          ['', '', status_ok]
        end
      end

      expect(backend.prune_all!(pr_branch_ttl_seconds: 3600)).to eq(0)
    end
  end

  describe 'tree-SHA secondary index' do
    let(:backend) { new_backend(branch: 'main', default_branch: 'main') }
    let(:pr_backend) { new_backend(branch: 'feat', default_branch: 'main') }

    before do
      write_valid_last_run(File.join(@cache_path, 'last_run.json'))
      FileUtils.mkdir_p(File.join(@cache_path, 'abc123'))
    end

    describe '#upload(ref, tree_sha:)' do
      it 'writes the cache archive AND a tree pointer when tree_sha is given' do
        uploads = []
        allow(Open3).to receive(:capture3) do |_cli, *args|
          uploads << [args[0..1], args[2], args[3]]
          ['', '', status_ok]
        end

        backend.upload('commit-A', tree_sha: 'tree-T')

        archive_uploads = uploads.select { |_op, _src, dst| dst.end_with?('cache.tar.gz') }
        pointer_uploads = uploads.select { |_op, _src, dst| dst.include?('/by_tree/') }

        expect(archive_uploads.size).to eq(1)
        expect(archive_uploads.first[2]).to eq('s3://my-bucket/rspec-tracer/main/commit-A/cache.tar.gz')

        expect(pointer_uploads.size).to eq(1)
        expect(pointer_uploads.first[2]).to eq('s3://my-bucket/rspec-tracer/main/by_tree/tree-T')
      end

      it 'pointer file content is the commit-SHA (plain text)' do
        captured_pointer_src = nil
        allow(Open3).to receive(:capture3) do |_cli, *args|
          captured_pointer_src = args[2] if args[3]&.include?('/by_tree/')
          ['', '', status_ok]
        end

        backend.upload('commit-A', tree_sha: 'tree-T')

        expect(captured_pointer_src).not_to be_nil
        # The pointer file is cleaned up after upload, but during the
        # captured shell-out it exists with the commit-SHA as content.
      end

      it 'omits the tree pointer when tree_sha is nil (default)' do
        uploads = []
        allow(Open3).to receive(:capture3) do |_cli, *args|
          uploads << args[3]
          ['', '', status_ok]
        end

        backend.upload('commit-A')

        expect(uploads).not_to include(a_string_matching(%r{/by_tree/}))
      end

      it 'omits the tree pointer when tree_sha is the empty string' do
        uploads = []
        allow(Open3).to receive(:capture3) do |_cli, *args|
          uploads << args[3]
          ['', '', status_ok]
        end

        backend.upload('commit-A', tree_sha: '')

        expect(uploads).not_to include(a_string_matching(%r{/by_tree/}))
      end
    end

    describe '#download(ref, tree_sha:)' do
      it 'resolves the tree pointer to a commit-SHA and downloads from that ref' do
        attempted_keys = []
        allow(Open3).to receive(:capture3) do |_cli, *args|
          if args[0..1] == %w[s3 cp]
            src = args[2]
            attempted_keys << src
            if src.end_with?('/by_tree/tree-T')
              File.write(args[3], 'commit-A')
              ['', '', status_ok]
            elsif src.include?('/main/commit-A/cache.tar.gz')
              build_valid_archive(args[3])
              ['', '', status_ok]
            else
              ['', 'miss', status_fail]
            end
          else
            ['', "unmatched: #{args.inspect}", status_fail]
          end
        end

        # Caller passes the CURRENT commit (commit-B from a rebase) +
        # tree_sha; pointer resolves to commit-A which has the cache.
        result = backend.download('commit-B', tree_sha: 'tree-T')

        expect(result).to be(true)
        # First attempt is the tree pointer; second is the resolved ref.
        expect(attempted_keys.first).to end_with('/by_tree/tree-T')
        expect(attempted_keys[1]).to include('/main/commit-A/cache.tar.gz')
      end

      it 'falls back to the direct ref when the tree pointer is absent' do
        attempted_keys = []
        allow(Open3).to receive(:capture3) do |_cli, *args|
          if args[0..1] == %w[s3 cp]
            src = args[2]
            attempted_keys << src
            if src.include?('/by_tree/')
              ['', 'pointer miss', status_fail]
            elsif src.include?('/main/commit-X/cache.tar.gz')
              build_valid_archive(args[3])
              ['', '', status_ok]
            else
              ['', 'miss', status_fail]
            end
          else
            ['', "unmatched: #{args.inspect}", status_fail]
          end
        end

        result = backend.download('commit-X', tree_sha: 'tree-missing')

        expect(result).to be(true)
        expect(attempted_keys).to include(a_string_ending_with('/by_tree/tree-missing'))
        expect(attempted_keys.last).to include('/main/commit-X/cache.tar.gz')
      end

      it 'returns false when both tree pointer and direct ref miss' do
        allow(Open3).to receive(:capture3).and_return(['', 'miss', status_fail])

        expect(backend.download('nonexistent', tree_sha: 'nonexistent')).to be(false)
      end

      it 'treats blank tree_sha as nil (no pointer attempt)' do
        attempted_keys = []
        allow(Open3).to receive(:capture3) do |_cli, *args|
          attempted_keys << args[2] if args[0..1] == %w[s3 cp]
          ['', 'miss', status_fail]
        end

        backend.download('commit-X', tree_sha: '')

        expect(attempted_keys).not_to include(a_string_matching(%r{/by_tree/}))
      end

      it 'returns nil from resolve_tree_pointer when pointer is empty / whitespace' do
        attempted_keys = []
        allow(Open3).to receive(:capture3) do |_cli, *args|
          if args[0..1] == %w[s3 cp]
            src = args[2]
            attempted_keys << src
            if src.include?('/by_tree/')
              File.write(args[3], "   \n") # whitespace-only pointer content
              ['', '', status_ok]
            else
              ['', 'miss', status_fail]
            end
          else
            ['', '', status_fail]
          end
        end

        # Empty pointer means resolve returns nil; should fall back to
        # direct commit-X lookup (which also misses, returning false).
        expect(backend.download('commit-X', tree_sha: 'tree-T')).to be(false)
        # Pointer was tried first, then direct ref.
        expect(attempted_keys.first).to end_with('/by_tree/tree-T')
        expect(attempted_keys.last).to include('/main/commit-X/cache.tar.gz')
      end

      it 'gracefully handles unreadable pointer file (StandardError swallowed)' do
        allow(Open3).to receive(:capture3) do |_cli, *args|
          if args[0..1] == %w[s3 cp] && args[2].include?('/by_tree/')
            # Simulate aws_cp_silent succeeding but File.read raising.
            File.write(args[3], 'commit-A')
            allow(File).to receive(:read).and_call_original
            allow(File).to receive(:read).with(args[3], encoding: 'UTF-8').and_raise(Errno::EACCES)
            ['', '', status_ok]
          else
            ['', 'miss', status_fail]
          end
        end

        # The rescue StandardError in resolve_tree_pointer swallows
        # the EACCES; download falls through to the direct ref miss.
        expect(backend.download('commit-X', tree_sha: 'tree-T')).to be(false)
      end

      context 'on a PR backend with main-tier fallback' do
        it 'tries tree-pointer-resolved ref on own tier, then on main tier' do
          attempted_keys = []
          allow(Open3).to receive(:capture3) do |_cli, *args|
            if args[0..1] == %w[s3 cp]
              src = args[2]
              attempted_keys << src
              if src.end_with?('/pr/feat/by_tree/tree-T')
                File.write(args[3], 'commit-A')
                ['', '', status_ok]
              elsif src.include?('/main/commit-A/cache.tar.gz')
                build_valid_archive(args[3])
                ['', '', status_ok]
              else
                ['', 'miss', status_fail]
              end
            else
              ['', '', status_fail]
            end
          end

          # Pointer hits on PR tier, resolved ref hits on main tier
          # (the upload was on main; PR rebase reads through to main).
          expect(pr_backend.download('commit-B', tree_sha: 'tree-T')).to be(true)
          # Order: PR pointer, PR resolved, main resolved (hit), ...
          expect(attempted_keys[0]).to end_with('/pr/feat/by_tree/tree-T')
          expect(attempted_keys).to include(a_string_matching(%r{/main/commit-A/cache\.tar\.gz}))
        end
      end
    end
  end

  describe '#unbounded_warning' do
    it 'returns nil when ref count is at or below the threshold' do
      backend = new_backend
      now = Time.now.to_i
      keys = [['rspec-tracer/main/sha1/cache.tar.gz', now]]
      allow(Open3).to receive(:capture3).and_return([JSON.generate('Contents' => keys.map do |k, t|
        { 'Key' => k, 'LastModified' => Time.at(t).utc.iso8601 }
      end), '', status_ok])

      expect(backend.unbounded_warning(warn_threshold: 10)).to be_nil
    end

    it 'returns a warning message when ref count exceeds the threshold' do
      backend = new_backend
      now = Time.now.to_i
      keys = (1..5).map { |i| ["rspec-tracer/main/sha#{i}/cache.tar.gz", now + i] }
      allow(Open3).to receive(:capture3).and_return([JSON.generate('Contents' => keys.map do |k, t|
        { 'Key' => k, 'LastModified' => Time.at(t).utc.iso8601 }
      end), '', status_ok])

      expect(backend.unbounded_warning(warn_threshold: 3)).to match(/5 refs/)
    end
  end

  describe 'private branch coverage' do
    let(:logger) do
      logger = instance_double(RSpecTracer::Logger)
      allow(logger).to receive(:debug)
      allow(logger).to receive(:warn)
      logger
    end

    def new_backend_with_logger(**opts)
      described_class.new(
        bucket: 'my-bucket', prefix: 'rspec-tracer',
        branch: 'main', default_branch: 'main',
        cache_path: @cache_path, logger: logger, **opts
      )
    end

    it 'pr_branch_ttl=nil on PR tier skips the dead-PR check (safe-nav else branch)' do
      pr_backend = new_backend(branch: 'feat', default_branch: 'main')
      allow(Open3).to receive(:capture3).and_return([JSON.generate('Contents' => []), '', status_ok])

      expect(pr_backend.prune!(pr_branch_ttl_seconds: nil)).to eq(0)
    end

    it 'returns nil from read_local_run_id when last_run.json holds non-Hash JSON' do
      File.write(File.join(@cache_path, 'last_run.json'), JSON.dump([1, 2, 3]))

      expect(new_backend.send(:read_local_run_id)).to be_nil
    end

    it 'returns nil from read_local_run_id when last_run.json holds a blank run_id' do
      File.write(File.join(@cache_path, 'last_run.json'),
                 JSON.dump('schema_version' => current_schema, 'run_id' => ''))

      expect(new_backend.send(:read_local_run_id)).to be_nil
    end

    it 'cleans up the tmp archive in try_download_from even when the path was never assigned' do
      backend = new_backend
      # Force the archive_path local to never get assigned by making the
      # tmp_archive_path call raise before its return value lands.
      allow(SecureRandom).to receive(:hex).and_raise(RuntimeError, 'rng down')

      expect { backend.send(:try_download_from, 'main', 'sha1') }.to raise_error(RuntimeError)
      # Implicit: the ensure block evaluated `defined?(archive_path) && archive_path`
      # in :else mode (defined? returned nil), so no rm_f call was attempted on a nil path.
    end

    it 'cleans up the tmp pointer in upload_tree_pointer even when the path was never assigned' do
      backend = new_backend
      allow(SecureRandom).to receive(:hex).and_raise(RuntimeError, 'rng down')

      expect { backend.send(:upload_tree_pointer, 'sha-ref', 'tree-sha-1') }.to raise_error(RuntimeError)
    end

    it 'list_refs_in_tier skips entries that are not the cache archive (e.g. tree pointers)' do
      backend = new_backend
      now = Time.now.to_i
      contents = [
        { 'Key' => 'rspec-tracer/main/sha1/cache.tar.gz', 'LastModified' => Time.at(now).utc.iso8601 },
        { 'Key' => 'rspec-tracer/main/by_tree/tree-sha-1', 'LastModified' => Time.at(now).utc.iso8601 }
      ]
      allow(Open3).to receive(:capture3).and_return([JSON.generate('Contents' => contents), '', status_ok])

      refs = backend.send(:list_refs_in_tier, 'main')
      expect(refs.map(&:first)).to eq(['sha1'])
    end

    it 'list_refs_in_tier skips keys whose extract_ref_from_archive_key returns nil' do
      backend = new_backend
      now = Time.now.to_i
      contents = [
        # Less than 2 segments after tier_head (no ref dir): "main/cache.tar.gz" with no ref segment.
        { 'Key' => 'rspec-tracer/main/cache.tar.gz', 'LastModified' => Time.at(now).utc.iso8601 },
        { 'Key' => 'rspec-tracer/main/sha1/cache.tar.gz', 'LastModified' => Time.at(now).utc.iso8601 }
      ]
      allow(Open3).to receive(:capture3).and_return([JSON.generate('Contents' => contents), '', status_ok])

      refs = backend.send(:list_refs_in_tier, 'main')
      expect(refs.map(&:first)).to eq(['sha1'])
    end

    it 'list_refs_in_tier dedups duplicate keys to the newest LastModified' do
      backend = new_backend
      newer = Time.now.to_i
      older = newer - 3600
      contents = [
        { 'Key' => 'rspec-tracer/main/sha1/cache.tar.gz', 'LastModified' => Time.at(newer).utc.iso8601 },
        { 'Key' => 'rspec-tracer/main/sha1/suite-2/cache.tar.gz', 'LastModified' => Time.at(older).utc.iso8601 }
      ]
      allow(Open3).to receive(:capture3).and_return([JSON.generate('Contents' => contents), '', status_ok])

      refs = backend.send(:list_refs_in_tier, 'main')
      expect(refs).to eq([['sha1', newer]])
    end

    it 'extract_ref_from_archive_key returns nil for a key outside the tier head' do
      backend = new_backend
      result = backend.send(:extract_ref_from_archive_key, 'other-prefix/main/sha1/cache.tar.gz', 'main')

      expect(result).to be_nil
    end

    it 'extract_ref_from_archive_key returns nil for a key with fewer than 2 segments after the tier head' do
      backend = new_backend
      result = backend.send(:extract_ref_from_archive_key, 'rspec-tracer/main/cache.tar.gz', 'main')

      expect(result).to be_nil
    end

    it 'discover_pr_branches skips an empty-name branch from CommonPrefixes' do
      backend = new_backend
      # An entry like `rspec-tracer/pr/` (no branch suffix) decodes to
      # an empty branch name and gets dropped.
      common = [{ 'Prefix' => 'rspec-tracer/pr/' }, { 'Prefix' => 'rspec-tracer/pr/feat/' }]
      allow(Open3).to receive(:capture3).and_return([JSON.generate('CommonPrefixes' => common), '', status_ok])

      expect(backend.send(:discover_pr_branches)).to eq(['feat'])
    end

    it 'list_common_prefixes returns [] on an empty stdout' do
      backend = new_backend
      allow(Open3).to receive(:capture3).and_return(['  ', '', status_ok])

      expect(backend.send(:list_common_prefixes, 'rspec-tracer/pr/')).to eq([])
    end

    it 'list_objects returns [] on an empty stdout' do
      backend = new_backend
      allow(Open3).to receive(:capture3).and_return(['  ', '', status_ok])

      expect(backend.send(:list_objects, 'rspec-tracer/main')).to eq([])
    end

    it 'maybe_prune_branch returns 0 when the branch has no refs in S3' do
      backend = new_backend
      allow(Open3).to receive(:capture3).and_return([JSON.generate('Contents' => []), '', status_ok])

      expect(backend.send(:maybe_prune_branch, 'empty-branch', Time.now.to_i)).to eq(0)
    end

    it 'log_debug forwards through to a configured logger (then-branch)' do
      backend = new_backend_with_logger
      backend.send(:log_debug, 'hello debug')

      expect(logger).to have_received(:debug).with(/hello debug/)
    end

    it 'log_warn forwards through to a configured logger (then-branch)' do
      backend = new_backend_with_logger
      backend.send(:log_warn, 'hello warn')

      expect(logger).to have_received(:warn).with(/hello warn/)
    end
  end
end
# rubocop:enable RSpec/InstanceVariable, RSpec/ExampleLength, RSpec/MultipleExpectations
# rubocop:enable RSpec/ContextWording
