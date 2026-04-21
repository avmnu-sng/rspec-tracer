# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'rspec_tracer/tracker/io_hooks'
require 'rantly/rspec_extensions'

# Property: for any N >= 1 and any file under project root with an
# allowed extension, reading that file N times within a single bucket
# produces exactly one Input (identity-keyed dedup).
#
# rubocop:disable RSpec/ExampleLength
RSpec.describe RSpecTracer::Tracker::IOHooks do
  # Outer mktmpdir is per-example but all 100 property iterations
  # share it - rewriting the fixture each property iteration would
  # defeat the point of measuring idempotence.
  let(:tmp_base) { Dir.mktmpdir }
  let(:root) { File.join(tmp_base, 'project').tap { |p| FileUtils.mkdir_p(p) } }
  let(:fixture) do
    path = File.join(root, 'fixture.yml')
    File.write(path, "a: 1\n")
    path
  end

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  around do |example|
    described_class.install(root: root)
    example.run
  ensure
    described_class.uninstall
  end

  it 'keeps bucket size at 1 across any number of repeat reads' do
    path = fixture # memoize per example
    property_of { range(1, 50) }.check(100) do |repeats|
      bucket = {}
      described_class.with_bucket(bucket) { repeats.times { File.read(path) } }
      expect(bucket.size).to eq(1)
    end
  end
end
# rubocop:enable RSpec/ExampleLength
