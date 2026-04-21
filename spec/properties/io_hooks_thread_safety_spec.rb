# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'rspec_tracer/tracker/io_hooks'
require 'rantly/rspec_extensions'

# Generator lives at module scope so `property_of` (which evaluates
# in Rantly's instance context) can reach it.
module IOHooksPropertyGen
  module_function

  def alpha_name
    word = Rantly { string(:alpha) }
    word.empty? ? 'a' : word
  end
end

# Property: concurrent threads running under distinct with_bucket
# calls see disjoint bucket contents. Each thread's bucket contains
# only its own reads, even though the hook ancestry chain is shared.
#
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
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

  def write_fixture_in(dir, name)
    path = File.join(dir, "#{name}.yml")
    File.write(path, "k: #{name}\n")
    path
  end

  it 'isolates buckets across threads reading distinct files' do
    dir = root # memoize per example (let is per-thread, let! isn't threadsafe here)
    property_of { [IOHooksPropertyGen.alpha_name, IOHooksPropertyGen.alpha_name] }.check(100) do |name_a, name_b|
      next if name_a == name_b

      fixture_a = write_fixture_in(dir, name_a)
      fixture_b = write_fixture_in(dir, name_b)
      bucket_a = {}
      bucket_b = {}

      t_a = Thread.new { described_class.with_bucket(bucket_a) { File.read(fixture_a) } }
      t_b = Thread.new { described_class.with_bucket(bucket_b) { File.read(fixture_b) } }
      [t_a, t_b].each(&:join)

      expect(bucket_a.keys).to eq(["data:#{name_a}.yml"])
      expect(bucket_b.keys).to eq(["data:#{name_b}.yml"])
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
