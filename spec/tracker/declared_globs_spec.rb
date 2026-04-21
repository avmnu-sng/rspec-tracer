# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'set'
require 'tmpdir'
require 'rspec_tracer/tracker/declared_globs'

RSpec.describe RSpecTracer::Tracker::DeclaredGlobs do
  let(:tmp_base) { Dir.mktmpdir }
  let(:root) { File.join(tmp_base, 'project').tap { |p| FileUtils.mkdir_p(p) } }

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  def write_file(rel, contents = "x\n")
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  describe '#initialize' do
    it 'expands the root to an absolute path' do
      walker = described_class.new(root: Pathname.new(root).relative_path_from(Pathname.new(Dir.pwd)).to_s)

      expect(walker.root).to eq(File.expand_path(root))
    end

    it 'freezes the supplied globs list' do
      walker = described_class.new(root: root, globs: ['lib/**/*.rb'])

      expect(walker.globs).to be_frozen
    end

    it 'defaults globs to an empty frozen list' do
      walker = described_class.new(root: root)

      expect(walker.globs).to eq([]).and be_frozen
    end

    it 'coerces non-string globs to strings' do
      walker = described_class.new(root: root, globs: [Pathname.new('lib/foo.rb')])

      expect(walker.globs).to eq(['lib/foo.rb'])
    end

    it 'flattens nested arrays of globs' do
      walker = described_class.new(root: root, globs: [['a.rb'], ['b.rb']])

      expect(walker.globs).to eq(%w[a.rb b.rb])
    end

    it 'de-duplicates identical globs' do
      walker = described_class.new(root: root, globs: %w[lib/**/*.rb lib/**/*.rb])

      expect(walker.globs).to eq(['lib/**/*.rb'])
    end

    it 'drops nil globs' do
      walker = described_class.new(root: root, globs: [nil, 'lib/foo.rb', nil])

      expect(walker.globs).to eq(['lib/foo.rb'])
    end
  end

  describe '#walk' do
    it 'returns an empty set when no globs are declared' do
      walker = described_class.new(root: root)

      expect(walker.walk).to eq(Set.new)
    end

    it 'emits :declared Inputs for every matching file' do
      write_file('db/schema.rb', "schema\n")
      walker = described_class.new(root: root, globs: ['db/schema.rb'])

      expect(walker.walk.map(&:kind)).to eq([:declared])
    end

    it 'digests each match with SHA256 hex' do
      write_file('db/schema.rb', "schema\n")
      walker = described_class.new(root: root, globs: ['db/schema.rb'])

      expect(walker.walk.first.digest).to eq(Digest::SHA256.hexdigest("schema\n"))
    end

    it 'expands paths to absolute form' do
      path = write_file('db/schema.rb')
      walker = described_class.new(root: root, globs: ['db/schema.rb'])

      expect(walker.walk.first.path).to eq(File.expand_path(path))
    end

    it 'tags the Input identity with the :declared kind' do
      write_file('db/schema.rb')
      walker = described_class.new(root: root, globs: ['db/schema.rb'])

      expect(walker.walk.first.identity).to eq('declared:db/schema.rb')
    end

    it 'walks recursive `**` globs' do
      write_file('lib/a.rb')
      write_file('lib/nested/b.rb')
      walker = described_class.new(root: root, globs: ['lib/**/*.rb'])

      expect(walker.walk.map(&:identity)).to contain_exactly('declared:lib/a.rb', 'declared:lib/nested/b.rb')
    end

    it 'supports extglob alternation like {a,b}/**/*.rb' do
      %w[app/x.rb lib/y.rb other/z.rb].each { |rel| write_file(rel) }
      walker = described_class.new(root: root, globs: ['{app,lib}/**/*.rb'])

      expect(walker.walk.map(&:identity))
        .to contain_exactly('declared:app/x.rb', 'declared:lib/y.rb')
    end

    it 'skips directories that happen to match the glob' do
      FileUtils.mkdir_p(File.join(root, 'lib/matched_dir'))
      walker = described_class.new(root: root, globs: ['lib/*'])

      expect(walker.walk).to eq(Set.new)
    end

    it 'de-duplicates files matched by multiple globs' do
      write_file('db/schema.rb')
      walker = described_class.new(root: root, globs: ['db/*.rb', 'db/schema.rb'])

      expect(walker.walk.size).to eq(1)
    end

    it 'returns an empty set when globs match nothing' do
      walker = described_class.new(root: root, globs: ['never/matches/*.rb'])

      expect(walker.walk).to eq(Set.new)
    end

    it 'memoizes the result across calls' do
      write_file('a.rb')
      walker = described_class.new(root: root, globs: ['a.rb'])

      expect(walker.walk).to equal(walker.walk)
    end

    it 'does not re-digest on a second call (proves memoization)' do
      write_file('a.rb', "v1\n")
      walker = described_class.new(root: root, globs: ['a.rb'])
      first = walker.walk.first.digest
      File.write(File.join(root, 'a.rb'), "v2\n")

      expect(walker.walk.first.digest).to eq(first)
    end

    it 'skips a path when digesting raises (graceful degradation)' do
      write_file('boom.rb')
      walker = described_class.new(root: root, globs: ['boom.rb'])
      allow(Digest::SHA256).to receive(:file).and_raise(Errno::EACCES)

      expect(walker.walk).to eq(Set.new)
    end

    it 'drops paths a glob resolved outside root (e.g. absolute glob escape)' do
      outside = File.join(tmp_base, 'outside.rb')
      File.write(outside, "x\n")
      walker = described_class.new(root: root, globs: [outside])

      expect(walker.walk).to eq(Set.new)
    end
  end

  describe '#covers?' do
    it 'returns false when no globs are declared' do
      walker = described_class.new(root: root)

      expect(walker.covers?(File.join(root, 'anything.rb'))).to be(false)
    end

    it 'returns false for paths outside root' do
      walker = described_class.new(root: root, globs: ['**/*.rb'])

      expect(walker.covers?('/elsewhere/a.rb')).to be(false)
    end

    it 'matches a literal filename' do
      walker = described_class.new(root: root, globs: ['db/schema.rb'])

      expect(walker.covers?(File.join(root, 'db/schema.rb'))).to be(true)
    end

    it 'matches a recursive `**` glob' do
      walker = described_class.new(root: root, globs: ['lib/**/*.rb'])

      expect(walker.covers?(File.join(root, 'lib/nested/foo.rb'))).to be(true)
    end

    it 'does not match paths the glob excludes' do
      walker = described_class.new(root: root, globs: ['lib/**/*.rb'])

      expect(walker.covers?(File.join(root, 'app/foo.rb'))).to be(false)
    end

    it 'does not match paths equal to root (no trailing separator)' do
      walker = described_class.new(root: root, globs: ['**/*'])

      expect(walker.covers?(root)).to be(false)
    end

    it 'supports extglob alternation' do
      walker = described_class.new(root: root, globs: ['{app,lib}/**/*.rb'])

      expect(walker.covers?(File.join(root, 'app/foo.rb'))).to be(true)
    end
  end

  describe '#attribute_to' do
    it 'returns an empty hash for no example ids' do
      walker = described_class.new(root: root, globs: ['db/schema.rb'])

      expect(walker.attribute_to([])).to eq({})
    end

    it 'attaches the declared inputs to every supplied example id' do
      write_file('db/schema.rb')
      walker = described_class.new(root: root, globs: ['db/schema.rb'])

      attribution = walker.attribute_to(%w[ex1 ex2])

      expect(attribution.keys).to contain_exactly('ex1', 'ex2')
    end

    it 'returns identity-equal Input sets per example' do
      write_file('db/schema.rb')
      walker = described_class.new(root: root, globs: ['db/schema.rb'])

      attribution = walker.attribute_to(%w[ex1 ex2])

      expect(attribution['ex1']).to eq(attribution['ex2'])
    end

    it 'returns distinct Set instances so per-example mutation stays local' do
      write_file('db/schema.rb')
      walker = described_class.new(root: root, globs: ['db/schema.rb'])

      attribution = walker.attribute_to(%w[ex1 ex2])
      attribution['ex1'].clear

      expect(attribution['ex2']).not_to be_empty
    end

    it 'contains Inputs with the :declared kind' do
      write_file('db/schema.rb')
      walker = described_class.new(root: root, globs: ['db/schema.rb'])

      attribution = walker.attribute_to(%w[ex1])

      expect(attribution['ex1'].map(&:kind)).to eq([:declared])
    end
  end

  describe 'end-to-end change detection' do
    # Proves AC: a declared file's digest changes when its contents
    # change - the signal that drives "re-run everything depending on
    # this input" in M3.5/M3.6.
    it 'returns a new digest when the declared file is modified between runs' do
      path = write_file('db/schema.rb', "v1\n")
      v1_digest = described_class.new(root: root, globs: ['db/schema.rb']).walk.first.digest
      File.write(path, "v2\n")
      v2_digest = described_class.new(root: root, globs: ['db/schema.rb']).walk.first.digest

      expect(v1_digest).not_to eq(v2_digest)
    end
  end
end
