# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'rspec_tracer/tracker/io_hooks'
require 'rspec_tracer/tracker/io_hooks/kernel'

RSpec.describe RSpecTracer::Tracker::IOHooks::KernelReads do
  let(:tmp_base) { Dir.mktmpdir }
  let(:root) { File.join(tmp_base, 'project').tap { |p| FileUtils.mkdir_p(p) } }
  let(:bucket) { {} }
  let(:ruby_fixture) do
    path = File.join(root, 'loader.rb')
    File.write(path, "# empty\n")
    path
  end

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  around do |example|
    RSpecTracer::Tracker::IOHooks.install(root: root)
    example.run
  ensure
    RSpecTracer::Tracker::IOHooks.uninstall
  end

  describe '#load' do
    it 'records an explicit Kernel.load call as :ruby' do
      RSpecTracer::Tracker::IOHooks.with_bucket(bucket) { Kernel.load(ruby_fixture) }

      expect(bucket).to have_key('ruby:loader.rb')
    end

    it 'records an implicit load call via method-body dispatch' do
      RSpecTracer::Tracker::IOHooks.with_bucket(bucket) { load(ruby_fixture) }

      expect(bucket).to have_key('ruby:loader.rb')
    end

    # Kernel.load on a non-.rb file raises at parse time - we're
    # only asserting that the hook itself doesn't add a bucket entry.
    it 'does not record non-.rb load paths' do
      non_ruby = File.join(root, 'loader.yml').tap { |p| File.write(p, "k: v\n") }
      RSpecTracer::Tracker::IOHooks.with_bucket(bucket) { safely_load(non_ruby) }

      expect(bucket).not_to have_key('ruby:loader.yml')
    end

    def safely_load(path)
      Kernel.load(path)
    rescue ScriptError, StandardError
      nil
    end
  end
end
