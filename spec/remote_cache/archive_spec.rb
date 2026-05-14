# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'

require 'rspec_tracer/remote_cache/archive'

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable
RSpec.describe RSpecTracer::RemoteCache::Archive do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def build_cache(run_id: 'abc123', file_count: 3)
    src = File.join(@dir, 'src')
    FileUtils.mkdir_p(File.join(src, run_id))
    File.write(File.join(src, 'last_run.json'),
               JSON.pretty_generate('schema_version' => 5, 'run_id' => run_id))
    file_count.times do |i|
      File.write(File.join(src, run_id, "file#{i}.json"),
                 JSON.pretty_generate('k' => 'v' * 100))
    end
    src
  end

  describe '.pack' do
    it 'writes a valid tar.gz containing last_run.json + all run-dir JSONs' do
      src = build_cache(run_id: 'abc', file_count: 4)
      dest = File.join(@dir, 'out.tar.gz')

      result = described_class.pack(cache_path: src, run_id: 'abc', dest_path: dest)

      expect(result).to eq(dest)
      expect(File.size(dest)).to be > 0
    end

    it 'raises on missing last_run.json' do
      src = File.join(@dir, 'src')
      FileUtils.mkdir_p(src)

      expect { described_class.pack(cache_path: src, run_id: 'abc', dest_path: File.join(@dir, 'x.tar.gz')) }
        .to raise_error(ArgumentError, /missing last_run\.json/)
    end

    it 'raises on missing run dir' do
      src = File.join(@dir, 'src')
      FileUtils.mkdir_p(src)
      File.write(File.join(src, 'last_run.json'), '{}')

      expect { described_class.pack(cache_path: src, run_id: 'abc', dest_path: File.join(@dir, 'x.tar.gz')) }
        .to raise_error(ArgumentError, /missing run dir/)
    end

    it 'raises when cache_path is nil or empty' do
      expect { described_class.pack(cache_path: nil, run_id: 'a', dest_path: 'x') }
        .to raise_error(ArgumentError, /cache_path/)
      expect { described_class.pack(cache_path: '', run_id: 'a', dest_path: 'x') }
        .to raise_error(ArgumentError, /cache_path/)
    end

    it 'raises when run_id is nil or empty' do
      src = build_cache
      expect { described_class.pack(cache_path: src, run_id: nil, dest_path: 'x') }
        .to raise_error(ArgumentError, /run_id/)
      expect { described_class.pack(cache_path: src, run_id: '', dest_path: 'x') }
        .to raise_error(ArgumentError, /run_id/)
    end

    it 'raises when dest_path is nil or empty' do
      src = build_cache
      expect { described_class.pack(cache_path: src, run_id: 'abc123', dest_path: nil) }
        .to raise_error(ArgumentError, /dest_path/)
      expect { described_class.pack(cache_path: src, run_id: 'abc123', dest_path: '') }
        .to raise_error(ArgumentError, /dest_path/)
    end
  end

  describe '.extract' do
    it 'round-trips the cache contents bit-for-bit' do
      src = build_cache(run_id: 'run-xyz', file_count: 5)
      dest = File.join(@dir, 'out.tar.gz')
      described_class.pack(cache_path: src, run_id: 'run-xyz', dest_path: dest)

      extract_dir = File.join(@dir, 'extract')
      described_class.extract(archive_path: dest, dest_dir: extract_dir)

      expect(File.read(File.join(extract_dir, 'last_run.json')))
        .to eq(File.read(File.join(src, 'last_run.json')))
      5.times do |i|
        expect(File.read(File.join(extract_dir, 'run-xyz', "file#{i}.json")))
          .to eq(File.read(File.join(src, 'run-xyz', "file#{i}.json")))
      end
    end

    it 'creates the dest_dir when it does not exist' do
      src = build_cache
      dest = File.join(@dir, 'out.tar.gz')
      described_class.pack(cache_path: src, run_id: 'abc123', dest_path: dest)

      extract_dir = File.join(@dir, 'does', 'not', 'yet', 'exist')
      described_class.extract(archive_path: dest, dest_dir: extract_dir)

      expect(File.directory?(extract_dir)).to be(true)
      expect(File.file?(File.join(extract_dir, 'last_run.json'))).to be(true)
    end

    it 'raises on a missing archive' do
      expect { described_class.extract(archive_path: '/nonexistent.tar.gz', dest_dir: @dir) }
        .to raise_error(ArgumentError, /missing archive/)
    end

    it 'raises on nil/empty archive_path' do
      expect { described_class.extract(archive_path: nil, dest_dir: @dir) }
        .to raise_error(ArgumentError, /archive_path/)
      expect { described_class.extract(archive_path: '', dest_dir: @dir) }
        .to raise_error(ArgumentError, /archive_path/)
    end

    it 'raises on nil/empty dest_dir' do
      expect { described_class.extract(archive_path: 'x.tar.gz', dest_dir: nil) }
        .to raise_error(ArgumentError, /dest_dir/)
      expect { described_class.extract(archive_path: 'x.tar.gz', dest_dir: '') }
        .to raise_error(ArgumentError, /dest_dir/)
    end

    it 'raises on a corrupt archive (not valid gzip)' do
      bad = File.join(@dir, 'bad.tar.gz')
      File.write(bad, 'not a valid tar.gz')

      expect { described_class.extract(archive_path: bad, dest_dir: File.join(@dir, 'out')) }
        .to raise_error(Zlib::GzipFile::Error)
    end

    it 'refuses archive entries with absolute paths (path-traversal defense)' do
      # Build a tar.gz with a malicious absolute path entry.
      require 'rubygems/package'
      require 'zlib'
      malicious = File.join(@dir, 'malicious.tar.gz')
      File.open(malicious, 'wb') do |file|
        Zlib::GzipWriter.wrap(file) do |gz|
          Gem::Package::TarWriter.new(gz) do |tar|
            tar.add_file_simple('/etc/passwd-malicious', 0o644, 4) { |io| io.write('bad!') }
            tar.add_file_simple('last_run.json', 0o644, 2) { |io| io.write('{}') }
          end
        end
      end

      out = File.join(@dir, 'out')
      described_class.extract(archive_path: malicious, dest_dir: out)

      expect(File.exist?('/etc/passwd-malicious')).to be(false)
      expect(File.exist?(File.join(out, 'last_run.json'))).to be(true)
    end

    it 'refuses archive entries with .. traversal' do
      require 'rubygems/package'
      require 'zlib'
      malicious = File.join(@dir, 'traversal.tar.gz')
      File.open(malicious, 'wb') do |file|
        Zlib::GzipWriter.wrap(file) do |gz|
          Gem::Package::TarWriter.new(gz) do |tar|
            tar.add_file_simple('../evil', 0o644, 4) { |io| io.write('bad!') }
            tar.add_file_simple('last_run.json', 0o644, 2) { |io| io.write('{}') }
          end
        end
      end

      out = File.join(@dir, 'sandbox')
      described_class.extract(archive_path: malicious, dest_dir: out)

      expect(File.exist?(File.join(@dir, 'evil'))).to be(false)
      expect(File.exist?(File.join(out, 'last_run.json'))).to be(true)
    end

    it 'skips non-file entries (directory-only tar entries)' do
      require 'rubygems/package'
      require 'zlib'
      archive = File.join(@dir, 'dir_only.tar.gz')
      File.open(archive, 'wb') do |file|
        Zlib::GzipWriter.wrap(file) do |gz|
          Gem::Package::TarWriter.new(gz) do |tar|
            tar.mkdir('some_dir', 0o755)
          end
        end
      end

      out = File.join(@dir, 'out')
      expect { described_class.extract(archive_path: archive, dest_dir: out) }.not_to raise_error
    end
  end

  describe '.safe_entry_name' do
    it 'returns nil on a nil entry name' do
      expect(described_class.safe_entry_name(nil)).to be_nil
    end

    it 'returns nil on an empty entry name' do
      expect(described_class.safe_entry_name('')).to be_nil
    end

    it 'returns nil on an absolute path' do
      expect(described_class.safe_entry_name('/etc/passwd')).to be_nil
    end

    it 'returns nil on a path containing parent traversal' do
      expect(described_class.safe_entry_name('foo/../etc/passwd')).to be_nil
    end

    it 'returns the name unchanged on a well-formed relative entry' do
      expect(described_class.safe_entry_name('run_id/file.json')).to eq('run_id/file.json')
    end
  end

  describe 'compression ratio' do
    it 'compresses redundant JSON meaningfully (~3-6x typical)' do
      # Compression is opportunistic, not guaranteed; the assertion is
      # "non-trivial gain on JSON-shaped input," not a fixed ratio.
      src = build_cache(run_id: 'abc', file_count: 10)
      original_total = Dir[File.join(src, '**', '*.json')].sum { |p| File.size(p) }
      dest = File.join(@dir, 'out.tar.gz')
      described_class.pack(cache_path: src, run_id: 'abc', dest_path: dest)

      expect(File.size(dest)).to be < (original_total / 2)
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable
