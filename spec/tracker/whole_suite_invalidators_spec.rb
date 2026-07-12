# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'
require 'rspec_tracer/tracker/whole_suite_invalidators'

RSpec.describe RSpecTracer::Tracker::WholeSuiteInvalidators do
  let(:tmp_base) { Dir.mktmpdir }
  let(:root) { File.join(tmp_base, 'project').tap { |p| FileUtils.mkdir_p(p) } }

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  def write_watch(rel, contents)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  describe '#initialize' do
    it 'expands root to an absolute path' do
      invs = described_class.new(root: root)

      expect(invs.root).to eq(File.expand_path(root))
    end

    it 'defaults gem_version to RSpecTracer::VERSION' do
      invs = described_class.new(root: root)

      expect(invs.gem_version).to eq(RSpecTracer::VERSION)
    end

    it 'accepts an explicit gem_version override' do
      invs = described_class.new(root: root, gem_version: '9.9.9')

      expect(invs.gem_version).to eq('9.9.9')
    end
  end

  describe '#digest_snapshot' do
    it 'always includes the gem identity key' do
      invs = described_class.new(root: root)

      expect(invs.digest_snapshot).to have_key(described_class::GEM_IDENTITY_KEY)
    end

    it 'hashes gem identity with SHA256 over "rspec-tracer-<version>"' do
      invs = described_class.new(root: root, gem_version: '1.2.3')

      expect(invs.digest_snapshot[described_class::GEM_IDENTITY_KEY])
        .to eq(Digest::SHA256.hexdigest('rspec-tracer-1.2.3'))
    end

    it 'omits absent watch files rather than inserting a nil sentinel' do
      invs = described_class.new(root: root)

      expect(invs.digest_snapshot).not_to have_key('Gemfile.lock')
    end

    it 'digests Gemfile.lock with SHA256 hex when present' do
      write_watch('Gemfile.lock', "GEM\n")
      invs = described_class.new(root: root)

      expect(invs.digest_snapshot['Gemfile.lock'])
        .to eq(Digest::SHA256.hexdigest("GEM\n"))
    end

    it 'digests .ruby-version when present' do
      write_watch('.ruby-version', "3.3.10\n")
      invs = described_class.new(root: root)

      expect(invs.digest_snapshot['.ruby-version'])
        .to eq(Digest::SHA256.hexdigest("3.3.10\n"))
    end

    it 'digests .rspec-tracer when present' do
      write_watch('.rspec-tracer', "RSpecTracer.configure {}\n")
      invs = described_class.new(root: root)

      expect(invs.digest_snapshot['.rspec-tracer'])
        .to eq(Digest::SHA256.hexdigest("RSpecTracer.configure {}\n"))
    end

    it 'returns a distinct digest on file-content changes' do
      write_watch('Gemfile.lock', "v1\n")
      invs = described_class.new(root: root)
      v1 = invs.digest_snapshot['Gemfile.lock']
      write_watch('Gemfile.lock', "v2\n")

      expect(invs.digest_snapshot['Gemfile.lock']).not_to eq(v1)
    end

    it 'skips a watch file when digesting raises (graceful degradation)' do
      write_watch('Gemfile.lock', "GEM\n")
      invs = described_class.new(root: root)
      allow(Digest::SHA256).to receive(:file).and_raise(Errno::EACCES)

      expect(invs.digest_snapshot).not_to have_key('Gemfile.lock')
    end
  end

  describe '#invalidated?' do
    let(:invs) { described_class.new(root: root) }

    it 'returns true when there is no previous snapshot (first run)' do
      expect(invs.invalidated?(nil)).to be(true)
    end

    it 'returns false when the current snapshot equals the previous' do
      snapshot = invs.digest_snapshot

      expect(invs.invalidated?(snapshot)).to be(false)
    end

    it 'returns true when a watch file appears' do
      previous = invs.digest_snapshot
      write_watch('Gemfile.lock', "GEM\n")

      expect(invs.invalidated?(previous)).to be(true)
    end

    it 'returns true when a watch file disappears' do
      write_watch('Gemfile.lock', "GEM\n")
      previous = invs.digest_snapshot
      File.delete(File.join(root, 'Gemfile.lock'))

      expect(invs.invalidated?(previous)).to be(true)
    end

    it 'returns true when a watch file content changes' do
      write_watch('Gemfile.lock', "v1\n")
      previous = invs.digest_snapshot
      write_watch('Gemfile.lock', "v2\n")

      expect(invs.invalidated?(previous)).to be(true)
    end

    it 'returns true when the gem version changes' do
      previous = described_class.new(root: root, gem_version: '1.0.0').digest_snapshot
      current = described_class.new(root: root, gem_version: '2.0.0')

      expect(current.invalidated?(previous)).to be(true)
    end

    it 'returns false for an unrelated file change under root' do
      write_watch('Gemfile.lock', "GEM\n")
      previous = invs.digest_snapshot
      write_watch('some/other.rb', "x\n")

      expect(invs.invalidated?(previous)).to be(false)
    end
  end

  describe 'end-to-end Gemfile.lock invalidation' do
    # Proves AC: modifying Gemfile.lock invalidates the snapshot,
    # which is the signal the filter translates into "re-run
    # every example, regardless of any other config."
    it 'fires on Gemfile.lock modification between runs' do
      write_watch('Gemfile.lock', "run1\n")
      run1 = described_class.new(root: root).digest_snapshot
      write_watch('Gemfile.lock', "run2\n")

      expect(described_class.new(root: root).invalidated?(run1)).to be(true)
    end
  end
end
