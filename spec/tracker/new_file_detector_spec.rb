# frozen_string_literal: true

require 'fileutils'
require 'set'
require 'tmpdir'
require 'rspec_tracer/tracker/new_file_detector'

RSpec.describe RSpecTracer::Tracker::NewFileDetector do
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
    it 'expands root to an absolute path' do
      detector = described_class.new(root: root)

      expect(detector.root).to eq(File.expand_path(root))
    end

    it 'expands a relative root via File.expand_path' do
      Dir.chdir(tmp_base) do
        detector = described_class.new(root: 'project')

        # macOS Dir.chdir resolves /var/folders/... -> /private/var/folders/...
        # via symlink, so equality across both expand_path calls is fragile.
        # Assert the absolute-path invariant directly so the mutation
        # `@root = root` (which would leave @root as 'project') registers.
        expect(detector.root).to match(%r{\A/.*/project\z})
      end
    end
  end

  describe '#new_files with empty cache' do
    it 'returns every file matching the default lib/**/*.rb glob' do
      write_file('lib/a.rb')
      write_file('lib/nested/b.rb')
      detector = described_class.new(root: root)

      expect(detector.new_files(known_paths: Set.new).map(&:identity))
        .to contain_exactly('declared:lib/a.rb', 'declared:lib/nested/b.rb')
    end

    it 'adds user-declared globs on top of the default set' do
      write_file('lib/a.rb')
      write_file('db/schema.rb')
      detector = described_class.new(root: root, declared_globs: ['db/schema.rb'])

      expect(detector.new_files(known_paths: Set.new).map(&:identity))
        .to contain_exactly('declared:lib/a.rb', 'declared:db/schema.rb')
    end

    it 'emits :declared kind for every new file' do
      write_file('lib/a.rb')
      detector = described_class.new(root: root)

      expect(detector.new_files(known_paths: Set.new).map(&:kind)).to eq([:declared])
    end
  end

  describe '#new_files filters out known paths' do
    it 'drops files whose absolute path is in known_paths' do
      path_a = write_file('lib/a.rb')
      write_file('lib/b.rb')
      detector = described_class.new(root: root)

      expect(detector.new_files(known_paths: Set[path_a]).map(&:identity))
        .to eq(['declared:lib/b.rb'])
    end

    it 'returns an empty set when every match is known' do
      a = write_file('lib/a.rb')
      b = write_file('lib/b.rb')
      detector = described_class.new(root: root)

      expect(detector.new_files(known_paths: Set[a, b])).to eq(Set.new)
    end

    it 'accepts an Array of known paths (to_set coerces)' do
      a = write_file('lib/a.rb')
      write_file('lib/b.rb')
      detector = described_class.new(root: root)

      expect(detector.new_files(known_paths: [a]).map(&:identity))
        .to eq(['declared:lib/b.rb'])
    end
  end

  describe '#new_files regression for KNOWN_ISSUES §B5' do
    # The bug: 1.x only diffs files already in cache.all_files, so a
    # newly-added source file is invisible to the invalidation path.
    # The fix: walk declared + default globs and emit Inputs for any
    # on-disk match not in the cache.
    it 'emits an Input for a file added between runs' do
      write_file('lib/existing.rb')
      run1_paths = described_class.new(root: root).new_files(known_paths: Set.new).map(&:path)
      write_file('lib/added.rb')

      run2 = described_class.new(root: root).new_files(known_paths: Set.new(run1_paths)).map(&:identity)

      expect(run2).to eq(['declared:lib/added.rb'])
    end
  end

  describe 'custom default_globs override' do
    it 'walks the supplied default set in place of lib/**/*.rb' do
      write_file('lib/not_walked.rb')
      write_file('custom/walked.rb')
      detector = described_class.new(root: root, default_globs: ['custom/**/*.rb'])

      expect(detector.new_files(known_paths: Set.new).map(&:identity))
        .to eq(['declared:custom/walked.rb'])
    end

    it 'accepts an empty default_globs list (user-declared only)' do
      %w[lib/ignored.rb db/schema.rb].each { |rel| write_file(rel) }
      detector = described_class.new(root: root, declared_globs: ['db/schema.rb'], default_globs: [])

      expect(detector.new_files(known_paths: Set.new).map(&:identity)).to eq(['declared:db/schema.rb'])
    end
  end

  describe 'glob de-duplication between declared and default sets' do
    it 'emits each file exactly once when declared and default globs overlap' do
      write_file('lib/overlap.rb')
      detector = described_class.new(
        root: root, declared_globs: ['lib/**/*.rb']
      )

      expect(detector.new_files(known_paths: Set.new).size).to eq(1)
    end
  end
end
