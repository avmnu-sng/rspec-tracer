# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'rspec_tracer/tracker/io_hooks'

RSpec.describe RSpecTracer::Tracker::IOHooks do
  let(:tmp_base) { Dir.mktmpdir }
  let(:root) { File.join(tmp_base, 'project').tap { |p| FileUtils.mkdir_p(p) } }

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  around do |example|
    described_class.install(root: root)
    example.run
  ensure
    described_class.uninstall
  end

  def write_fixture(rel, contents = "k: v\n")
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  describe '.install' do
    it 'marks the coordinator installed' do
      expect(described_class.installed?).to be(true)
    end

    it 'captures the expanded root' do
      expect(described_class.root).to eq(File.expand_path(root))
    end
  end

  describe '.uninstall' do
    it 'clears state and flips installed? to false' do
      described_class.uninstall

      expect(described_class.installed?).to be(false)
    end
  end

  describe '.with_bucket / .current_bucket' do
    # The outer suite's Engine#example_started sets a bucket via
    # ReporterHook on every example - post-M5.1, there is no
    # use_v2_tracker gate. Explicitly clear before asserting the
    # with_bucket lifecycle so `current_bucket` reads as `nil` when
    # nothing else has touched it inside the test.
    before { described_class.clear_bucket }

    it 'exposes the bucket inside the block' do
      bucket = {}
      captured = nil
      described_class.with_bucket(bucket) { captured = described_class.current_bucket }

      expect(captured).to be(bucket)
    end

    it 'restores the previous bucket after the block' do
      described_class.with_bucket({ outer: 1 }) do
        described_class.with_bucket({ inner: 1 }) { :noop }

        expect(described_class.current_bucket).to eq(outer: 1)
      end
    end

    it 'propagates the block exception' do
      expect { described_class.with_bucket({}) { raise 'boom' } }.to raise_error('boom')
    end

    it 'clears the bucket on exit even if the block raises' do
      begin
        described_class.with_bucket({}) { raise 'boom' }
      rescue StandardError
        # discard - we only care that the ensure ran
      end
      expect(described_class.current_bucket).to be_nil
    end
  end

  describe '.set_bucket / .clear_bucket' do
    it 'set_bucket installs a bucket readable via current_bucket' do
      bucket = {}
      described_class.set_bucket(bucket)
      expect(described_class.current_bucket).to be(bucket)
    ensure
      described_class.clear_bucket
    end

    it 'clear_bucket nils out the current bucket' do
      described_class.set_bucket({})
      described_class.clear_bucket

      expect(described_class.current_bucket).to be_nil
    end

    it 'wires the bucket so record captures through it (parity with with_bucket)' do
      bucket = {}
      described_class.set_bucket(bucket)
      described_class.record(write_fixture('a.yml'))
      described_class.clear_bucket
      expect(bucket).not_to be_empty
    end
  end

  describe '.record fast-reject' do
    it 'is a no-op when uninstalled' do
      described_class.uninstall
      bucket = {}
      described_class.with_bucket(bucket) { described_class.record(write_fixture('a.yml')) }

      expect(bucket).to be_empty
    end

    it 'is a no-op when no bucket is set' do
      expect { described_class.record(write_fixture('a.yml')) }.not_to raise_error
    end

    it 'is a no-op for paths outside root' do
      bucket = {}
      described_class.with_bucket(bucket) { described_class.record('/elsewhere/a.yml') }

      expect(bucket).to be_empty
    end

    it 'is a no-op for extensions outside the allow-set' do
      bucket = {}
      described_class.with_bucket(bucket) { described_class.record(write_fixture('a.txt')) }

      expect(bucket).to be_empty
    end

    it 'is a no-op when the user filter rejects' do
      described_class.install(root: root, filter: ->(_path) { false })
      bucket = {}
      described_class.with_bucket(bucket) { described_class.record(write_fixture('a.yml')) }

      expect(bucket).to be_empty
    end
  end

  describe '.record emit' do
    let(:bucket) { {} }
    let(:path) { write_fixture('config/locale.yml') }

    before { described_class.with_bucket(bucket) { described_class.record(path) } }

    it 'emits exactly one Input' do
      expect(bucket.size).to eq(1)
    end

    it 'tags the Input as :data' do
      expect(bucket.values.first.kind).to eq(:data)
    end

    it 'keys by identity (kind:relative_path)' do
      expect(bucket).to have_key('data:config/locale.yml')
    end

    it 'digests the file with SHA256 hex' do
      expect(bucket.values.first.digest).to match(/\A[0-9a-f]{64}\z/)
    end
  end

  describe '.record dedup' do
    let(:bucket) { {} }

    before do
      path = write_fixture('dup.yml', "a\n")
      described_class.with_bucket(bucket) do
        described_class.record(path)
        File.write(path, "b\n") # changes file mid-example
        described_class.record(path)
      end
    end

    it 'keeps exactly one Input' do
      expect(bucket.size).to eq(1)
    end

    # Digest reflects the *first* read - dedup short-circuits before
    # the second SHA256 call.
    it 'keeps the first read\'s digest' do
      expect(bucket.values.first.digest).to eq(Digest::SHA256.hexdigest("a\n"))
    end
  end

  describe '.record graceful degradation' do
    context 'when digesting raises' do
      let(:bucket) { {} }
      let(:path) { write_fixture('boom.yml') }

      before { allow(Digest::SHA256).to receive(:file).and_raise(Errno::EACCES) }

      it 'swallows the StandardError' do
        expect do
          described_class.with_bucket(bucket) { described_class.record(path) }
        end.not_to raise_error
      end

      it 'leaves the bucket empty' do
        described_class.with_bucket(bucket) { described_class.record(path) }
        expect(bucket).to be_empty
      end
    end

    it 'accepts a Pathname-like to_s-able argument' do
      path = write_fixture('pathname.yml')
      bucket = {}
      described_class.with_bucket(bucket) { described_class.record(Pathname.new(path)) }

      expect(bucket).not_to be_empty
    end
  end

  describe '.record_ruby_load' do
    it 'records .rb paths as :ruby' do
      path = write_fixture('loader.rb', "puts 1\n")
      bucket = {}
      described_class.with_bucket(bucket) { described_class.record_ruby_load(path) }

      expect(bucket.values.first.kind).to eq(:ruby)
    end

    it 'ignores non-.rb paths' do
      path = write_fixture('loader.yml')
      bucket = {}
      described_class.with_bucket(bucket) { described_class.record_ruby_load(path) }

      expect(bucket).to be_empty
    end
  end
end
