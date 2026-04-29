# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'rspec_tracer/filter'
require 'rspec_tracer/tracker/coverage_adapter'

RSpec.describe RSpecTracer::Tracker::CoverageAdapter do
  # Dir.mktmpdir gives a plain path; let memoizes it per-example, after
  # hook cleans up. Avoids instance variables that RSpec/InstanceVariable
  # flags while keeping write_file helpers in scope.
  let(:tmp_base) { Dir.mktmpdir }
  let(:root) do
    File.join(tmp_base, 'project').tap { |p| FileUtils.mkdir_p(p) }
  end

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  def write_file(rel, contents = "x = 1\n")
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  describe '#initialize' do
    it 'rejects invalid modes' do
      expect { described_class.new(root: root, mode: :bogus) }
        .to raise_error(ArgumentError, /invalid mode: :bogus/)
    end

    it 'accepts :auto, :array, and :hash' do
      %i[auto array hash].each do |m|
        expect(described_class.new(root: root, mode: m).mode).to eq(m)
      end
    end

    it 'expands the root' do
      adapter = described_class.new(root: "#{root}/.")
      expect(adapter.root).to eq(root)
    end

    it 'defaults filters to an empty array' do
      expect(described_class.new(root: root).filters).to eq([])
    end
  end

  describe '#compute_diff' do
    subject(:adapter) { described_class.new(root: root) }

    it 'returns an empty Set when before and after are identical' do
      expect(adapter.compute_diff({}, {})).to eq(Set.new)
    end

    it 'returns an empty Set when line arrays match element-wise' do
      path = write_file('same.rb')
      diff = adapter.compute_diff({ path => [1, nil, 0] }, { path => [1, nil, 0] })
      expect(diff).to be_empty
    end

    context 'when line counts changed' do
      let(:path) { write_file('foo.rb') }
      let(:diff) { adapter.compute_diff({ path => [0, 0, 0] }, { path => [1, 0, 0] }) }

      it 'emits one Input' do
        expect(diff.size).to eq(1)
      end

      it 'tags the Input as :ruby' do
        expect(diff.first.kind).to eq(:ruby)
      end

      it 'sets the Input path to the changed file' do
        expect(diff.first.path).to eq(path)
      end

      it 'digests the file with SHA256 hex' do
        expect(diff.first.digest).to match(/\A[0-9a-f]{64}\z/)
      end
    end

    it 'emits an Input for files appearing only in after' do
      path = write_file('new.rb')
      diff = adapter.compute_diff({}, { path => [1] })
      expect(diff.map(&:path)).to eq([path])
    end

    it 'emits an Input for files appearing only in before' do
      path = write_file('gone.rb')
      diff = adapter.compute_diff({ path => [1] }, {})
      expect(diff.map(&:path)).to eq([path])
    end

    it 'treats nil/nil on the same index as no change' do
      path = write_file('x.rb')
      diff = adapter.compute_diff({ path => [nil, nil, 1] }, { path => [nil, nil, 1] })
      expect(diff).to be_empty
    end

    it 'treats nil->number as a change (a previously-unexecuted line ran)' do
      path = write_file('x.rb')
      diff = adapter.compute_diff({ path => [nil, 0] }, { path => [1, 0] })
      expect(diff).not_to be_empty
    end

    it 'treats a length change (file body grew) as a change' do
      path = write_file('x.rb')
      diff = adapter.compute_diff({ path => [1] }, { path => [1, 1] })
      expect(diff).not_to be_empty
    end

    context 'when the observed file no longer exists on disk' do
      let(:absent) { File.join(root, 'absent.rb') }
      let(:diff) { adapter.compute_diff({ absent => [1] }, {}) }

      it 'still emits an Input for the disappeared file' do
        expect(diff.size).to eq(1)
      end

      it 'yields a nil digest' do
        expect(diff.first.digest).to be_nil
      end
    end

    it 'yields a nil digest when reading the file raises SystemCallError' do
      path = write_file('readfail.rb')
      allow(Digest::SHA256).to receive(:file).and_raise(Errno::EACCES)
      diff = adapter.compute_diff({ path => [1] }, { path => [2] })

      expect(diff.first.digest).to be_nil
    end

    it 'is a pure function - does not mutate its arguments' do
      path = write_file('pure.rb')
      before = { path => [0] }.freeze
      after = { path => [1] }.freeze

      expect { adapter.compute_diff(before, after) }.not_to raise_error
    end
  end

  describe '#peek' do
    let(:inside_root) { write_file('lib/foo.rb', "puts 1\n") }
    let(:outside_root) { '/elsewhere/lib/foo.rb' }

    it 'filters files to under the project root' do
      allow(Coverage).to receive(:peek_result).and_return(
        inside_root => [1], outside_root => [1]
      )
      adapter = described_class.new(root: root)

      expect(adapter.peek.keys).to eq([inside_root])
    end

    it 'normalizes hash-mode (SimpleCov branch tracking) to line arrays' do
      allow(Coverage).to receive(:peek_result).and_return(
        inside_root => { lines: [1, 0], branches: { foo: {} } }
      )
      adapter = described_class.new(root: root, mode: :hash)

      expect(adapter.peek).to eq(inside_root => [1, 0])
    end

    it 'auto-detects :hash mode from the first value shape' do
      allow(Coverage).to receive(:peek_result)
        .and_return(inside_root => { lines: [1], branches: {} })
      adapter = described_class.new(root: root).tap(&:peek)

      expect(adapter.mode).to eq(:hash)
    end

    it 'auto-detects :array mode from the first value shape' do
      allow(Coverage).to receive(:peek_result).and_return(inside_root => [1])
      adapter = described_class.new(root: root)
      adapter.peek

      expect(adapter.mode).to eq(:array)
    end

    it 'stays in :array mode when ::Coverage.peek_result is empty' do
      allow(Coverage).to receive(:peek_result).and_return({})
      adapter = described_class.new(root: root)
      adapter.peek

      expect(adapter.mode).to eq(:array)
    end

    it 'applies legacy-compatible filters keyed on file_name' do
      allow(Coverage).to receive(:peek_result).and_return(inside_root => [1])
      filter = RSpecTracer::Filter.register(%r{/lib/foo\.rb\z})
      adapter = described_class.new(root: root, filters: [filter])

      expect(adapter.peek).to be_empty
    end

    it 'does not apply filters when the list is empty' do
      allow(Coverage).to receive(:peek_result).and_return(inside_root => [1])
      adapter = described_class.new(root: root, filters: [])

      expect(adapter.peek).to eq(inside_root => [1])
    end
  end

  describe '#peek_unfiltered' do
    let(:inside_root) { write_file('lib/foo.rb', "puts 1\n") }
    let(:outside_root) { '/elsewhere/lib/foo.rb' }

    it 'filters by root prefix only (skips the user filters list)' do
      filter = RSpecTracer::Filter.register(%r{/lib/foo\.rb\z})
      allow(Coverage).to receive(:peek_result).and_return(inside_root => [1], outside_root => [1])
      adapter = described_class.new(root: root, filters: [filter])

      expect(adapter.peek_unfiltered.keys).to eq([inside_root])
    end

    it 'normalizes hash-mode entries to line arrays' do
      allow(Coverage).to receive(:peek_result).and_return(
        inside_root => { lines: [1, 0], branches: {} }
      )
      adapter = described_class.new(root: root, mode: :hash)

      expect(adapter.peek_unfiltered).to eq(inside_root => [1, 0])
    end
  end
end
