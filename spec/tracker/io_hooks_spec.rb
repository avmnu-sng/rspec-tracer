# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tmpdir'
require 'yaml'
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

  # An Object that explicitly reports it cannot stringify — exercises
  # `_record`'s `path.is_a?(String) || path.respond_to?(:to_s)` guard's
  # then-branch (early-return because both checks fail).
  def build_not_stringable
    Object.new.tap do |obj|
      obj.define_singleton_method(:respond_to?) { |method, *| method != :to_s }
    end
  end

  describe '.install' do
    it 'marks the coordinator installed' do
      expect(described_class.installed?).to be(true)
    end

    it 'captures the expanded root' do
      expect(described_class.root).to eq(File.expand_path(root))
    end

    it 'expands a relative root via File.expand_path' do
      Dir.chdir(tmp_base) do
        described_class.install(root: 'project')

        expect(described_class.root).to match(%r{\A/.*/project\z})
      end
    end

    it 'defaults filter to a lambda that accepts every path' do
      bucket = {}
      described_class.with_bucket(bucket) { described_class.record(write_fixture('config/locale.yml')) }

      expect(bucket).not_to be_empty
    end

    it 'wires @root_prefix so subsequent records produce relative-path identities' do
      # Verifies `@root_prefix = "#{@root}/"` (not "#{nil}/" or some other
      # variant) by exercising end-to-end identity construction.
      bucket = {}
      described_class.with_bucket(bucket) { described_class.record(write_fixture('config/locale.yml')) }

      expect(bucket).to have_key('data:config/locale.yml')
    end

    it 'defaults extensions to DEFAULT_EXTENSIONS (covers .haml among others)' do
      # .haml is in DEFAULT_EXTENSIONS but not a typical user-supplied
      # filter; if the default ever narrows, this test breaks.
      bucket = {}
      described_class.with_bucket(bucket) { described_class.record(write_fixture('view.haml')) }

      expect(bucket).not_to be_empty
    end

    it 'prepends FileReads onto File.singleton_class' do
      expect(File.singleton_class.ancestors).to include(described_class::FileReads)
    end

    it 'prepends IOReads onto IO.singleton_class' do
      expect(IO.singleton_class.ancestors).to include(described_class::IOReads)
    end

    it 'prepends YAMLReads onto YAML.singleton_class' do
      expect(YAML.singleton_class.ancestors).to include(described_class::YAMLReads)
    end

    it 'prepends JSONReads onto JSON.singleton_class' do
      expect(JSON.singleton_class.ancestors).to include(described_class::JSONReads)
    end

    it 'prepends KernelReads onto Kernel.singleton_class' do
      expect(Kernel.singleton_class.ancestors).to include(described_class::KernelReads)
    end

    it 'prepends KernelReads onto Kernel itself for implicit-load dispatch' do
      # Kernel.load via `Kernel.load 'x'` hits the singleton_class chain;
      # implicit `load 'x'` in a method body dispatches via Object's
      # ancestor chain through Kernel-as-module. Both must be hooked.
      expect(Kernel.ancestors).to include(described_class::KernelReads)
    end

    it 'skips the YAMLReads prepend when ::YAML is not loaded' do
      described_class.uninstall
      hide_const('YAML')

      # The require_relative above already loaded YAMLReads in the outer
      # around hook, so the constant is reachable; the if-defined? guard
      # in install just decides whether to call .prepend on ::YAML.
      expect { described_class.install(root: root) }.not_to raise_error
    end

    it 'skips the JSONReads prepend when ::JSON is not loaded' do
      described_class.uninstall
      hide_const('JSON')

      expect { described_class.install(root: root) }.not_to raise_error
    end
  end

  describe '.uninstall' do
    it 'clears state and flips installed? to false' do
      described_class.uninstall

      expect(described_class.installed?).to be(false)
    end

    it 'clears @root so a stale value cannot leak post-uninstall' do
      described_class.uninstall

      expect(described_class.root).to be_nil
    end

    it 'reduces record to a no-op (every hook fast-rejects on nil @root_prefix)' do
      described_class.uninstall
      bucket = {}
      described_class.with_bucket(bucket) { described_class.record(write_fixture('post.yml')) }

      expect(bucket).to be_empty
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
      # The outer rspec-tracer ReporterHook installs a bucket on every
      # example; clear it explicitly so _record's `bucket.nil?` guard
      # actually fires (the early-return :then branch).
      described_class.clear_bucket

      expect { described_class.record(write_fixture('a.yml')) }.not_to raise_error
    end

    it 'is a no-op when path is neither a String nor responds to to_s' do
      bucket = {}
      not_stringable = build_not_stringable
      described_class.with_bucket(bucket) { described_class.record(not_stringable) }

      expect(bucket).to be_empty
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

    context 'when Input.for_file raises (downstream defensive rescue)' do
      let(:bucket) { {} }
      let(:path) { write_fixture('downstream.yml') }

      before do
        allow(RSpecTracer::Tracker::Input).to receive(:for_file).and_raise(StandardError, 'boom')
      end

      it 'swallows the StandardError raised by the downstream Input builder' do
        expect do
          described_class.with_bucket(bucket) { described_class.record(path) }
        end.not_to raise_error
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
