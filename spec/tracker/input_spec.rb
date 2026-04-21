# frozen_string_literal: true

require 'fileutils'
require 'set'
require 'tmpdir'
require 'rspec_tracer/tracker/input'

RSpec.describe RSpecTracer::Tracker::Input do
  let(:root) { '/tmp/project' }

  describe '.for_file' do
    let(:input) do
      described_class.for_file(
        path: '/tmp/project/lib/foo.rb', kind: :ruby, digest: 'abc', root: root
      )
    end

    it 'returns a frozen value' do
      expect(input).to be_frozen
    end

    it 'stores the absolute path' do
      expect(input.path).to eq('/tmp/project/lib/foo.rb')
    end

    it 'stores the kind' do
      expect(input.kind).to eq(:ruby)
    end

    it 'stores the digest' do
      expect(input.digest).to eq('abc')
    end

    it 'precomputes the identity as kind:relative_path' do
      expect(input.identity).to eq('ruby:lib/foo.rb')
    end

    context 'with a relative input path' do
      # .for_file expands via File.expand_path which is cwd-relative; on
      # macOS the Dir.chdir target differs from Dir.pwd because of the
      # /tmp → /private/tmp symlink resolution. Compute expectations
      # through Dir.pwd so the test is filesystem-agnostic.
      let(:tmp_base) { Dir.mktmpdir }
      let(:canonical) { Dir.chdir(tmp_base) { File.join(Dir.pwd, 'project') } }
      let(:rel_input) do
        Dir.chdir(tmp_base) do
          described_class.for_file(
            path: 'project/lib/foo.rb', kind: :ruby, digest: 'd', root: canonical
          )
        end
      end

      after { FileUtils.rm_rf(tmp_base) if tmp_base }

      it 'expands the path against the cwd' do
        expect(rel_input.path).to eq(File.join(canonical, 'lib/foo.rb'))
      end

      it 'still produces the canonical relative identity' do
        expect(rel_input.identity).to eq('ruby:lib/foo.rb')
      end
    end

    context 'when the path escapes root' do
      let(:escape_input) do
        described_class.for_file(
          path: '/elsewhere/lib/foo.rb', kind: :ruby, digest: 'abc', root: root
        )
      end

      it 'falls back to the absolute path inside the identity' do
        expect(escape_input.identity).to eq('ruby:/elsewhere/lib/foo.rb')
      end
    end

    context 'when path equals root (no trailing separator match)' do
      let(:root_path_input) do
        described_class.for_file(path: root, kind: :ruby, digest: 'x', root: root)
      end

      it 'falls back to the absolute path rather than emit an empty relative' do
        expect(root_path_input.identity).to eq("ruby:#{root}")
      end
    end

    it 'rejects unknown kinds' do
      expect do
        described_class.for_file(path: '/x.rb', kind: :bogus, digest: 'd', root: '/')
      end.to raise_error(ArgumentError, /invalid Input kind: :bogus/)
    end

    RSpecTracer::Tracker::ALLOWED_INPUT_KINDS.each do |kind|
      it "accepts kind=#{kind}" do
        input = described_class.for_file(
          path: "/tmp/project/x_#{kind}", kind: kind, digest: 'd', root: root
        )

        expect(input.kind).to eq(kind)
      end
    end
  end

  describe '.relative_path' do
    it 'strips the root prefix and the separator' do
      expect(described_class.relative_path('/a/b/c.rb', '/a')).to eq('b/c.rb')
    end

    it 'expands the supplied root before comparing' do
      expect(described_class.relative_path('/a/b/c.rb', '/a/')).to eq('b/c.rb')
    end

    it 'returns the absolute path unchanged when it is outside root' do
      expect(described_class.relative_path('/x/y.rb', '/a')).to eq('/x/y.rb')
    end
  end

  describe '#stale?' do
    let(:input) do
      described_class.for_file(
        path: '/tmp/p/x', kind: :ruby, digest: 'abc', root: '/tmp/p'
      )
    end

    it 'is stale when the current digest differs' do
      expect(input.stale?('def')).to be(true)
    end

    it 'is not stale when the digests match' do
      expect(input.stale?('abc')).to be(false)
    end

    it 'is stale when the current digest is nil (input disappeared)' do
      expect(input.stale?(nil)).to be(true)
    end
  end

  describe 'equality' do
    def build(path:, kind: :ruby, digest: 'a', root: '/tmp/p')
      described_class.for_file(path: path, kind: kind, digest: digest, root: root)
    end

    let(:a) { build(path: '/tmp/p/x') }
    let(:same_id_diff_digest) { build(path: '/tmp/p/x', digest: 'other') }
    let(:diff_path) { build(path: '/tmp/p/y') }
    let(:same_path_diff_kind) { build(path: '/tmp/p/x', kind: :data) }

    it 'considers two Inputs == when identities match (digest ignored)' do
      expect(a).to eq(same_id_diff_digest)
    end

    it 'considers two Inputs eql? when identities match' do
      expect(a.eql?(same_id_diff_digest)).to be(true)
    end

    it 'gives identity-equal Inputs the same hash' do
      expect(a.hash).to eq(same_id_diff_digest.hash)
    end

    it 'distinguishes Inputs by path' do
      expect(a).not_to eq(diff_path)
    end

    it 'distinguishes Inputs by kind' do
      expect(a).not_to eq(same_path_diff_kind)
    end

    it 'is not equal to a non-Input value with the same identity string' do
      expect(a).not_to eq('ruby:x')
    end

    it 'returns false for eql? against a non-Input' do
      expect(a.eql?('ruby:x')).to be(false)
    end

    it 'dedupes identity-equal Inputs inside a Set' do
      set = Set.new([a, same_id_diff_digest, diff_path])

      expect(set.size).to eq(2)
    end
  end
end
