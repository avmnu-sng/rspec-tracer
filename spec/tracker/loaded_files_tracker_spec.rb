# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'set'
require 'tmpdir'
require 'rspec_tracer/tracker/loaded_files_tracker'

# Injectable peek lambda keeps these specs deterministic and
# isolated from the process's real ::Coverage state (which may have
# been started by the outer harness). Every scenario constructs a
# tracker with an explicit peek list so we control exactly what
# "loaded" means at each boundary.
#
# Several examples need 2-3 setup lines (peek sequence + fixture
# writes) before the expectation - legitimate in a tracker that
# reacts to a stream of observations. File-level rubocop relax.
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe RSpecTracer::Tracker::LoadedFilesTracker do
  let(:tmp_base) { Dir.mktmpdir }
  let(:root) { File.join(tmp_base, 'project').tap { |p| FileUtils.mkdir_p(p) } }

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  def write_file(rel, contents = "x\n")
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  def peek_lambda(paths)
    -> { paths }
  end

  describe '#initialize' do
    it 'expands the root to an absolute path' do
      tracker = described_class.new(root: '.', peek: peek_lambda([]))

      expect(tracker.root).to eq(File.expand_path('.'))
    end

    it 'defaults to enabled' do
      tracker = described_class.new(root: root, peek: peek_lambda([]))

      expect(tracker.enabled?).to be(true)
    end

    it 'honors an explicit enabled: false' do
      tracker = described_class.new(root: root, peek: peek_lambda([]), enabled: false)

      expect(tracker.enabled?).to be(false)
    end

    it 'leaves boot_set nil until capture_boot_set! is called' do
      tracker = described_class.new(root: root, peek: peek_lambda([]))

      expect(tracker.boot_set).to be_nil
    end

    it 'starts with an empty loaded_set' do
      tracker = described_class.new(root: root, peek: peek_lambda([]))

      expect(tracker.loaded_set).to eq(Set.new)
    end

    it 'starts with zero loaded_set_size' do
      tracker = described_class.new(root: root, peek: peek_lambda([]))

      expect(tracker.loaded_set_size).to eq(0)
    end

    it 'accepts construction without a peek: argument (uses DEFAULT_PEEK)' do
      expect { described_class.new(root: root) }.not_to raise_error
    end
  end

  describe 'DEFAULT_PEEK' do
    it 'returns an array' do
      expect(described_class::DEFAULT_PEEK.call).to be_an(Array)
    end

    it 'reads from ::Coverage.peek_result.keys' do
      allow(Coverage).to receive(:peek_result).and_return('/fake/path.rb' => [])

      expect(described_class::DEFAULT_PEEK.call).to eq(['/fake/path.rb'])
    end
  end

  describe '#capture_boot_set!' do
    it 'captures the filtered peek result into a frozen Set' do
      path = write_file('lib/boot.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([path]))

      tracker.capture_boot_set!

      expect(tracker.boot_set).to eq(Set[path]).and be_frozen
    end

    it 'filters peek entries that fall outside the project root' do
      outside = File.join(tmp_base, 'outside.rb').tap { |p| File.write(p, "x\n") }
      inside = write_file('lib/inside.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([outside, inside]))

      tracker.capture_boot_set!

      expect(tracker.boot_set).to eq(Set[inside])
    end

    it 'drops non-string entries in the peek result' do
      inside = write_file('lib/inside.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([inside, 42, nil]))

      tracker.capture_boot_set!

      expect(tracker.boot_set).to eq(Set[inside])
    end

    it 'accepts String-subclass paths (is_a?(String) semantic, not instance_of?)' do
      string_subclass = Class.new(String)
      path = write_file('lib/custom.rb')
      custom = string_subclass.new(path)
      tracker = described_class.new(root: root, peek: peek_lambda([custom]))

      tracker.capture_boot_set!

      expect(tracker.boot_set.size).to eq(1)
    end

    it 'tolerates peek raising and captures an empty boot set' do
      tracker = described_class.new(root: root, peek: -> { raise 'boom' })

      tracker.capture_boot_set!

      expect(tracker.boot_set).to eq(Set.new).and be_frozen
    end

    it 'seeds loaded_set with the boot paths' do
      path = write_file('lib/boot.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([path]))

      tracker.capture_boot_set!

      expect(tracker.loaded_set).to eq(Set[path])
    end

    it 'is idempotent - second call returns the original boot set' do
      path1 = write_file('lib/boot.rb')
      path2 = write_file('lib/late.rb')
      peek_sequence = [[path1], [path1, path2]]
      tracker = described_class.new(root: root, peek: -> { peek_sequence.shift })

      first = tracker.capture_boot_set!
      second = tracker.capture_boot_set!

      expect(second).to equal(first)
    end

    it 'idempotency does not re-peek on subsequent calls' do
      path = write_file('lib/boot.rb')
      peek_calls = 0
      peek = lambda do
        peek_calls += 1
        [path]
      end
      tracker = described_class.new(root: root, peek: peek)
      tracker.capture_boot_set!
      tracker.capture_boot_set!

      expect(peek_calls).to eq(1)
    end

    it 'returns an empty frozen Set when disabled' do
      path = write_file('lib/boot.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([path]), enabled: false)

      tracker.capture_boot_set!

      expect(tracker.boot_set).to eq(Set.new).and be_frozen
    end

    it 'does not consult peek when disabled' do
      peek_calls = 0
      peek = lambda do
        peek_calls += 1
        []
      end
      tracker = described_class.new(root: root, peek: peek, enabled: false)

      tracker.capture_boot_set!

      expect(peek_calls).to eq(0)
    end
  end

  describe '#boot_set_digest_snapshot' do
    it 'returns {} before capture_boot_set! is called' do
      tracker = described_class.new(root: root, peek: peek_lambda([]))

      expect(tracker.boot_set_digest_snapshot).to eq({})
    end

    it 'returns {} when disabled' do
      path = write_file('lib/a.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([path]), enabled: false)
      tracker.capture_boot_set!

      expect(tracker.boot_set_digest_snapshot).to eq({})
    end

    it 'maps every boot path to its SHA256 hex digest keyed by relative path' do
      path = write_file('lib/boot.rb', "boot\n")
      tracker = described_class.new(root: root, peek: peek_lambda([path]))
      tracker.capture_boot_set!

      expect(tracker.boot_set_digest_snapshot).to eq('lib/boot.rb' => Digest::SHA256.hexdigest("boot\n"))
    end

    it 'skips paths whose digest failed during capture' do
      path = write_file('lib/boot.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([path]))
      allow(Digest::SHA256).to receive(:file).and_raise(Errno::EACCES)
      tracker.capture_boot_set!

      expect(tracker.boot_set_digest_snapshot).to eq({})
    end

    it 'uses the absolute path as-is when it does not start under root_prefix' do
      # Reach past the public API to place a rogue path that bypassed
      # the capture-time filter - proves relative_path falls back
      # correctly rather than slicing a prefix that doesn't match.
      tracker = described_class.new(root: root, peek: peek_lambda([]))
      tracker.capture_boot_set!
      rogue = '/absolute/elsewhere.rb'
      tracker.instance_variable_set(:@boot_set, Set[rogue].freeze)
      tracker.instance_variable_set(:@input_cache, rogue => fake_input(rogue, 'deadbeef'))

      expect(tracker.boot_set_digest_snapshot).to eq(rogue => 'deadbeef')
    end

    def fake_input(path, digest)
      RSpecTracer::Tracker::Input.for_file(path: path, kind: :ruby, digest: digest, root: '/')
    end
  end

  describe '#boot_set_invalidated?' do
    it 'is false when disabled regardless of previous snapshot' do
      tracker = described_class.new(root: root, peek: peek_lambda([]), enabled: false)
      tracker.capture_boot_set!

      expect(tracker.boot_set_invalidated?(nil)).to be(false)
      expect(tracker.boot_set_invalidated?('lib/a.rb' => 'zzz')).to be(false)
    end

    it 'is false for a nil previous snapshot (first-run no-cache case)' do
      path = write_file('lib/boot.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([path]))
      tracker.capture_boot_set!

      expect(tracker.boot_set_invalidated?(nil)).to be(false)
    end

    it 'is false when the previous snapshot equals the current one' do
      path = write_file('lib/boot.rb', "boot\n")
      tracker = described_class.new(root: root, peek: peek_lambda([path]))
      tracker.capture_boot_set!

      previous = tracker.boot_set_digest_snapshot.dup

      expect(tracker.boot_set_invalidated?(previous)).to be(false)
    end

    it 'is true when the previous snapshot differs (content mutation)' do
      path = write_file('lib/boot.rb', "boot\n")
      tracker = described_class.new(root: root, peek: peek_lambda([path]))
      tracker.capture_boot_set!

      expect(tracker.boot_set_invalidated?('lib/boot.rb' => 'stale')).to be(true)
    end

    it 'is true when a previously-tracked path is missing from the current snapshot' do
      path = write_file('lib/boot.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([path]))
      tracker.capture_boot_set!

      expect(tracker.boot_set_invalidated?(tracker.boot_set_digest_snapshot.merge('lib/gone.rb' => 'zzz')))
        .to be(true)
    end
  end

  describe '#loaded_set_inputs' do
    it 'returns an empty Set before capture_boot_set!' do
      tracker = described_class.new(root: root, peek: peek_lambda([]))

      expect(tracker.loaded_set_inputs).to eq(Set.new)
    end

    it 'returns Set<Input> for every path in the loaded_set' do
      boot = write_file('lib/boot.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([boot]))
      tracker.capture_boot_set!

      inputs = tracker.loaded_set_inputs

      expect(inputs.map(&:path)).to contain_exactly(boot)
    end

    it 'tags every emitted Input with kind: :ruby' do
      boot = write_file('lib/boot.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([boot]))
      tracker.capture_boot_set!

      expect(tracker.loaded_set_inputs.map(&:kind)).to eq([:ruby])
    end

    it 'returns a fresh Set per call so downstream mutation stays local' do
      boot = write_file('lib/boot.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([boot]))
      tracker.capture_boot_set!

      first = tracker.loaded_set_inputs
      first.clear

      expect(tracker.loaded_set_inputs).not_to be_empty
    end

    it 'returns an empty Set when disabled' do
      boot = write_file('lib/boot.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([boot]), enabled: false)
      tracker.capture_boot_set!

      expect(tracker.loaded_set_inputs).to eq(Set.new)
    end
  end

  describe '#stop_example' do
    it 'returns an empty Set when disabled' do
      tracker = described_class.new(root: root, peek: peek_lambda([]), enabled: false)
      tracker.capture_boot_set!

      expect(tracker.stop_example('ex1')).to eq(Set.new)
    end

    it 'returns an empty Set and does no digest work when disabled even with unseen peek paths' do
      # Proves the enabled guard skips new_filtered_paths + build_inputs.
      # Under a dropped guard, stop_example would digest `boot` and emit an Input.
      boot = write_file('lib/boot.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([boot]), enabled: false)
      tracker.capture_boot_set!

      expect(tracker.stop_example('ex1')).to eq(Set.new)
    end

    it 'returns an empty Set when no paths have been newly loaded' do
      boot = write_file('lib/boot.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([boot]))
      tracker.capture_boot_set!

      expect(tracker.stop_example('ex1')).to eq(Set.new)
    end

    it 'returns Inputs for newly-loaded paths and grows @loaded_set' do
      boot = write_file('lib/boot.rb')
      lazy = write_file('lib/lazy.rb')
      peek_sequence = [[boot], [boot, lazy]]
      tracker = described_class.new(root: root, peek: -> { peek_sequence.shift })
      tracker.capture_boot_set!

      new_inputs = tracker.stop_example('ex1')

      expect(new_inputs.map(&:path)).to eq([lazy])
      expect(tracker.loaded_set).to include(boot, lazy)
    end

    it 'stop_example is monotonic - @loaded_set only grows across calls' do
      boot = write_file('lib/boot.rb')
      lazy_a = write_file('lib/lazy_a.rb')
      lazy_b = write_file('lib/lazy_b.rb')
      peek_sequence = [[boot], [boot, lazy_a], [boot, lazy_a, lazy_b]]
      tracker = described_class.new(root: root, peek: -> { peek_sequence.shift })
      tracker.capture_boot_set!
      tracker.stop_example('ex1')
      tracker.stop_example('ex2')

      expect(tracker.loaded_set).to include(boot, lazy_a, lazy_b)
    end

    it 'filters newly-observed paths outside the project root' do
      boot = write_file('lib/boot.rb')
      outside = File.join(tmp_base, 'outside.rb').tap { |p| File.write(p, "x\n") }
      peek_sequence = [[boot], [boot, outside]]
      tracker = described_class.new(root: root, peek: -> { peek_sequence.shift })
      tracker.capture_boot_set!

      expect(tracker.stop_example('ex1')).to eq(Set.new)
    end

    it 'drops non-string entries on the growing peek path' do
      # Proves the is_a?(String) guard in new_filtered_paths survives:
      # without it, path.start_with? on 42 / nil would raise NoMethodError.
      boot = write_file('lib/boot.rb')
      peek_sequence = [[boot], [boot, 42, nil]]
      tracker = described_class.new(root: root, peek: -> { peek_sequence.shift })
      tracker.capture_boot_set!

      expect(tracker.stop_example('ex1')).to eq(Set.new)
    end

    it 'reuses cached Inputs (no re-digesting) when a path was already observed' do
      boot = write_file('lib/boot.rb')
      lazy = write_file('lib/lazy.rb', "v1\n")
      peek_sequence = [[boot], [boot, lazy], [boot, lazy]]
      tracker = described_class.new(root: root, peek: -> { peek_sequence.shift })
      tracker.capture_boot_set!
      first = tracker.stop_example('ex1').first
      File.write(lazy, "v2\n")
      # Force re-peek that includes lazy again; its digest should not
      # be recomputed because the path is already in @loaded_set.
      tracker.stop_example('ex2')

      expect(tracker.loaded_set_inputs.find { |i| i.path == lazy }.digest).to eq(first.digest)
    end

    it 'skips paths whose digest fails (graceful degradation)' do
      boot = write_file('lib/boot.rb')
      lazy = write_file('lib/lazy.rb')
      peek_sequence = [[boot], [boot, lazy]]
      tracker = described_class.new(root: root, peek: -> { peek_sequence.shift })
      tracker.capture_boot_set!
      allow(Digest::SHA256).to receive(:file).and_raise(Errno::EACCES)

      new_inputs = tracker.stop_example('ex1')

      expect(new_inputs).to eq(Set.new)
    end

    it 'does not mark failed-digest paths as loaded (retry on next call)' do
      boot = write_file('lib/boot.rb')
      lazy = write_file('lib/lazy.rb')
      peek_sequence = [[boot], [boot, lazy]]
      tracker = described_class.new(root: root, peek: -> { peek_sequence.shift })
      tracker.capture_boot_set!
      allow(Digest::SHA256).to receive(:file).and_raise(Errno::EACCES)
      tracker.stop_example('ex1')

      expect(tracker.loaded_set).not_to include(lazy)
    end

    it 'skips newly-observed paths that have vanished from disk' do
      boot = write_file('lib/boot.rb')
      lazy = write_file('lib/lazy.rb')
      peek_sequence = [[boot], [boot, lazy]]
      tracker = described_class.new(root: root, peek: -> { peek_sequence.shift })
      tracker.capture_boot_set!
      File.delete(lazy)

      new_inputs = tracker.stop_example('ex1')

      expect(new_inputs).to eq(Set.new)
    end

    it 'tolerates peek raising inside stop_example (graceful degradation)' do
      peeks = 0
      peek = lambda do
        peeks += 1
        raise 'peek failed' if peeks > 1

        []
      end
      tracker = described_class.new(root: root, peek: peek)
      tracker.capture_boot_set!

      expect(tracker.stop_example('ex1')).to eq(Set.new)
    end
  end

  describe '#loaded_set / #loaded_set_size' do
    it '#loaded_set returns a defensive copy' do
      boot = write_file('lib/boot.rb')
      tracker = described_class.new(root: root, peek: peek_lambda([boot]))
      tracker.capture_boot_set!
      snapshot = tracker.loaded_set
      snapshot.clear

      expect(tracker.loaded_set_size).to eq(1)
    end

    it '#loaded_set_size reflects the current count' do
      boot = write_file('lib/boot.rb')
      lazy = write_file('lib/lazy.rb')
      peek_sequence = [[boot], [boot, lazy]]
      tracker = described_class.new(root: root, peek: -> { peek_sequence.shift })
      tracker.capture_boot_set!
      tracker.stop_example('ex1')

      expect(tracker.loaded_set_size).to eq(2)
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
