# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe RSpecTracer::SourceFile do
  describe '.file_path' do
    # When a spec's metadata[:file_path] resolves to an absolute path
    # outside RSpecTracer.root — common for shared examples from
    # vendored gems (/opt/bundle/gems/rspec-rails-X/lib/shared_examples/...)
    # or monorepo spec files adjacent to the project — the pre-fix
    # method stripped the leading "/" and expanded against
    # RSpecTracer.root, producing a non-existent <root>/opt/bundle/...
    # path. File.file? returned false, from_path returned nil, and the
    # tracer silently skipped dependency registration — a silent-
    # correctness bug leaving stale caches whenever the external file
    # changed. Closes the issue behind upstream PRs #37 and #67.
    context 'when given an absolute path outside RSpecTracer.root' do
      let(:tmp) { Dir.mktmpdir }

      after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

      it 'returns the absolute path unchanged when the file exists on disk' do
        external = File.join(tmp, 'vendored_shared_example.rb')
        File.write(external, "# shared example\n")

        expect(described_class.file_path(external)).to eq(external)
      end
    end

    context 'when given a project-relative path (leading / prefix stripped by file_name)' do
      it 'expands the path against RSpecTracer.root' do
        expanded = described_class.file_path('/spec/spec_helper.rb')

        expect(expanded).to eq(File.expand_path('spec/spec_helper.rb', RSpecTracer.root))
      end
    end
  end

  describe '.from_path' do
    let(:tmp) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

    # File.binread bypasses external-encoding transcoding and returns
    # raw bytes; Digest::MD5 hashes the byte content. Without binread,
    # a source file containing UTF-8 (helpers with inline Unicode, spec
    # files referencing "\u00A7") would crash on `LANG=`-unset shells
    # where Encoding.default_external resolves to US-ASCII.
    context 'when the source file contains UTF-8 bytes under US-ASCII default external' do
      let(:path) { File.join(tmp, 'unicode.rb') }
      let(:content) { "# section \u00A7 marker\n" }

      around do |example|
        original_external = Encoding.default_external
        original_verbose = $VERBOSE
        $VERBOSE = nil
        Encoding.default_external = Encoding::US_ASCII
        example.run
      ensure
        Encoding.default_external = original_external
        $VERBOSE = original_verbose
      end

      before { File.write(path, content, encoding: 'UTF-8') }

      it 'digests the file without raising' do
        expect { described_class.from_path(path) }.not_to raise_error
      end

      it 'returns a digest over the raw UTF-8 bytes' do
        expected = Digest::MD5.hexdigest(content.b)

        expect(described_class.from_path(path)[:digest]).to eq(expected)
      end

      it 'remains byte-identical to the digest under a UTF-8 default external' do
        digest_us_ascii = described_class.from_path(path)[:digest]

        Encoding.default_external = Encoding::UTF_8
        digest_utf8 = described_class.from_path(path)[:digest]

        expect(digest_us_ascii).to eq(digest_utf8)
      end
    end
  end
end
