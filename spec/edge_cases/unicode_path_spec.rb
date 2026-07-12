# frozen_string_literal: true

# Unicode in cache contents - file paths, example descriptions,
# example_ids, env names. The storage layer must round-trip every
# Unicode string identical to its input regardless of backend +
# serializer choice. Anything less is a silent data-loss bug.
#
# All Unicode test data is constructed AT RUNTIME from integer
# codepoints (`pack('U*')` / `chr(Encoding::UTF_8)`) so the spec
# source itself stays ASCII-only. mutant's parser reads lib/ as
# US-ASCII and crashes on non-ASCII bytes; spec files
# are not subjects, but defensively-ASCII-clean spec sources avoid
# any future tooling encoding-check surprise. The same posture
# applies to unicode_path_spec, hardlink_spec, etc.

require 'fileutils'
require 'json'
require 'set'
require 'tmpdir'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'

UNICODE_SPEC_SQLITE_AVAILABLE =
  begin
    require 'sqlite3'
    require 'rspec_tracer/storage/sqlite_backend'
    RUBY_ENGINE == 'ruby'
  rescue LoadError
    false
  end

# Build Unicode strings via codepoint integers so this spec source
# stays ASCII-only. Each string covers a different escape category:
# Latin-1 supplement, CJK, emoji, BMP combining mark.
module UnicodePathGen
  module_function

  def latin_supplement
    # "café" — Latin-1 e-acute
    [0x63, 0x61, 0x66, 0xE9].pack('U*')
  end

  def cjk
    # JP "テスト" — full-width katakana
    [0x30C6, 0x30B9, 0x30C8].pack('U*')
  end

  def emoji
    # Pile of poo + rocket — astral plane (4-byte UTF-8)
    [0x1F4A9, 0x1F680].pack('U*')
  end

  def combining_mark
    # "a" + combining acute
    [0x61, 0x0301].pack('U*')
  end

  def all
    {
      latin: latin_supplement,
      cjk: cjk,
      emoji: emoji,
      combining: combining_mark
    }
  end
end

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Unicode paths + descriptions in cache content' do
  let(:tmp_base) { Dir.mktmpdir('rspec_tracer_unicode_') }
  let(:cache_path) { File.join(tmp_base, 'cache') }
  let(:schema_version) { RSpecTracer::Storage::Schema::CURRENT }

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  def build_unicode_snapshot(serializer_marker)
    UnicodePathGen.all.each_with_object({}) { |(_, v), _| v.encoding } # touch encodings
    file_path = "/spec/#{UnicodePathGen.latin_supplement}/#{UnicodePathGen.cjk}.rb"
    desc = "describes the #{UnicodePathGen.emoji} feature with #{UnicodePathGen.combining_mark}"

    RSpecTracer::Storage::Snapshot.new(
      schema_version: RSpecTracer::Storage::Schema::CURRENT,
      run_id: "run-#{serializer_marker}-unicode",
      all_examples: { 'ex_unicode' => { id: 'ex_unicode', description: desc, file_path: file_path } },
      duplicate_examples: {},
      interrupted_examples: Set.new,
      flaky_examples: Set.new,
      failed_examples: Set.new,
      pending_examples: Set.new,
      skipped_examples: Set.new,
      all_files: { file_path => { file_name: file_path, file_path: file_path, digest: 'abc' } },
      dependency: { 'ex_unicode' => Set.new([file_path]) },
      reverse_dependency: { file_path => Set.new(['ex_unicode']) },
      examples_coverage: { 'ex_unicode' => { file_path => [1, nil, 2] } },
      boot_set: { "lib/#{UnicodePathGen.cjk}.rb" => 'deadbeef' },
      wsi_snapshot: { 'Gemfile.lock' => 'feedc0de' },
      env_snapshot: { UnicodePathGen.latin_supplement => 'facade1' },
      env_dependency: { 'ex_unicode' => [UnicodePathGen.latin_supplement] }
    )
  end

  shared_examples 'round-trips unicode strings identically' do
    it 'preserves unicode in file_path keys / values' do
      snap = backend.load_graph(schema_version: schema_version)
      file_path = "/spec/#{UnicodePathGen.latin_supplement}/#{UnicodePathGen.cjk}.rb"

      expect(snap.all_files).to have_key(file_path)
      expect(snap.dependency.fetch('ex_unicode')).to include(file_path)
    end

    it 'preserves astral-plane emoji codepoints in example descriptions' do
      snap = backend.load_graph(schema_version: schema_version)

      expect(snap.all_examples['ex_unicode'][:description]).to include(UnicodePathGen.emoji)
    end

    it 'preserves combining marks (multi-codepoint single grapheme)' do
      snap = backend.load_graph(schema_version: schema_version)

      expect(snap.all_examples['ex_unicode'][:description]).to include(UnicodePathGen.combining_mark)
    end

    it 'preserves CJK in boot_set keys' do
      snap = backend.load_graph(schema_version: schema_version)
      cjk_key = "lib/#{UnicodePathGen.cjk}.rb"

      expect(snap.boot_set).to have_key(cjk_key)
    end

    it 'preserves Latin-supplement in env_snapshot keys + env_dependency values' do
      snap = backend.load_graph(schema_version: schema_version)

      expect(snap.env_snapshot).to have_key(UnicodePathGen.latin_supplement)
      expect(snap.env_dependency.fetch('ex_unicode')).to include(UnicodePathGen.latin_supplement)
    end
  end

  describe 'JsonBackend with serializer: :json' do
    let(:backend) { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path, serializer: :json) }

    before do
      backend.save_graph(build_unicode_snapshot('json'), schema_version: schema_version)
    end

    it_behaves_like 'round-trips unicode strings identically'

    it 'writes the JSON files in UTF-8 (no \\u escaping forced; readable on disk)' do
      run_id = backend.last_run_id
      contents = File.read(File.join(cache_path, run_id, 'all_files.json'), encoding: 'UTF-8')

      # JSON.pretty_generate emits UTF-8 by default (no ASCII-only flag).
      expect(contents.encoding).to eq(Encoding::UTF_8)
      expect(contents).to include(UnicodePathGen.latin_supplement)
    end
  end

  describe 'JsonBackend with serializer: :msgpack' do
    let(:backend) { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path, serializer: :msgpack) }

    before do
      backend.save_graph(build_unicode_snapshot('msgpack'), schema_version: schema_version)
    end

    it_behaves_like 'round-trips unicode strings identically'
  end

  describe 'SqliteBackend' do
    before do
      skip 'sqlite3 gem not installable on this Ruby (JRuby or missing dep)' unless UNICODE_SPEC_SQLITE_AVAILABLE
      backend.save_graph(build_unicode_snapshot('sqlite'), schema_version: schema_version)
    end

    let(:backend) { RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path) }

    it_behaves_like 'round-trips unicode strings identically'
  end
end
# rubocop:enable RSpec/DescribeClass
