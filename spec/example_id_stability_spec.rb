# frozen_string_literal: true

require 'spec_helper'
require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# End-to-end regression for the long-standing example_id stability
# bug closed by 1.2.4.
#
# `example_id` (the MD5 RSpecTracer::Example.from produces) used to
# hash `example_group.name` — RSpec's generated class name, which
# carries a load-order-dependent `_2` / `_3` disambiguator suffix
# when two spec files share a describe-block name. Two files both
# `RSpec.describe 'Nice'` produced different example_ids depending
# on which file rspec loaded first, silently invalidating the cache.
#
# This subprocess-driven spec verifies the fix end-to-end: it writes
# a minimal fixture into a tmpdir (Gemfile pinned at the worktree's
# rspec-tracer path), runs `bundle exec rspec` against it in two
# different file load orders, and asserts the same example's id is
# stable across the orderings. Per-example mechanics are unit-tested
# in spec/lib/rspec_tracer/example_spec.rb; the subprocess form is
# the load-bearing test for RSpec's actual `example_group.description`
# behaviour under the multi-file scenario.
#
# Shared bundle install across the suite (set in before(:all), torn
# down in after(:all)) is intentional — the bundle is the test
# environment, not state that leaks between examples. Each example
# scrubs the tracer caches in its own before block.
# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/InstanceVariable, RSpec/BeforeAfterAll
RSpec.describe 'example_id stability across runs' do
  let(:tracer_root)  { File.expand_path('..', __dir__) }
  let(:cache_dir)    { File.join(@fixture_dir, 'rspec_tracer_cache') }
  let(:report_dir)   { File.join(@fixture_dir, 'rspec_tracer_report') }
  let(:coverage_dir) { File.join(@fixture_dir, 'rspec_tracer_coverage') }

  # Self-contained tmpdir fixture: Gemfile pins rspec-tracer at the
  # worktree path so the in-progress change is what the subprocess
  # exercises. Bundle install runs once for the whole describe; each
  # example scrubs the tracer caches before its subprocess invocation
  # so identity hashes are computed fresh.
  before(:all) do
    @fixture_dir = Dir.mktmpdir('rspec-tracer-id-stability-')
    write_fixture(@fixture_dir, tracer_root_path: File.expand_path('..', __dir__))
    bundle_install!(@fixture_dir)
  end

  after(:all) do
    FileUtils.rm_rf(@fixture_dir) if @fixture_dir
  end

  before do
    [cache_dir, report_dir, coverage_dir].each { |dir| FileUtils.rm_rf(dir) }
  end

  def write_fixture(dir, tracer_root_path:)
    File.write(File.join(dir, 'Gemfile'), <<~RUBY)
      source 'https://rubygems.org'
      gem 'rspec', '~> 3.13'
      gem 'simplecov', '~> 0.22'
      gem 'rspec-tracer', path: #{tracer_root_path.inspect}
    RUBY
    File.write(File.join(dir, '.rspec'), "--require spec_helper\n")
    FileUtils.mkdir_p(File.join(dir, 'spec'))
    File.write(File.join(dir, 'spec', 'spec_helper.rb'), <<~RUBY)
      require 'simplecov'
      SimpleCov.start
      require 'rspec_tracer'
      RSpecTracer.start
    RUBY
  end

  def bundle_install!(dir)
    Bundler.with_unbundled_env do
      out, status = Open3.capture2e('bundle', 'install', '--quiet', chdir: dir)
      raise "bundle install failed in #{dir}:\n#{out}" unless status.success?
    end
  end

  def write_spec(basename, body)
    rel = File.join('spec', "rt_idstab_#{basename}.rb")
    File.write(File.join(@fixture_dir, rel), body)
    rel
  end

  def run_rspec(*spec_files)
    Bundler.with_unbundled_env do
      out, status = Open3.capture2e(
        { 'RSPEC_TRACER_DISABLE' => nil },
        'bundle', 'exec', 'rspec', '--no-color', *spec_files, chdir: @fixture_dir
      )
      # rspec-tracer output may carry non-ASCII bytes; scrub for safe
      # matching regardless of the parent process's default encoding.
      [out.dup.force_encoding('UTF-8').scrub, status]
    end
  end

  def example_id_for(description_substring)
    last_run = JSON.parse(File.read(File.join(cache_dir, 'last_run.json'), encoding: 'UTF-8'))
    run_id = last_run.fetch('run_id')
    all_examples = JSON.parse(
      File.read(File.join(cache_dir, run_id, 'all_examples.json'), encoding: 'UTF-8')
    )
    found = all_examples.find { |_id, meta| meta['description']&.include?(description_substring) }
    found&.first
  end

  it 'keeps an example_id stable when two files share a describe name, regardless of load order' do
    file_a = write_spec('file_a_spec', <<~RUBY)
      RSpec.describe 'Shared Describe Name' do
        it 'identity case: example defined in file a' do
          expect(:a).to eq(:a)
        end
      end
    RUBY
    file_b = write_spec('file_b_spec', <<~RUBY)
      RSpec.describe 'Shared Describe Name' do
        it 'identity case: example defined in file b' do
          expect(:b).to eq(:b)
        end
      end
    RUBY

    out_ab, status_ab = run_rspec(file_a, file_b)
    expect(status_ab.exitstatus).to eq(0), "a-then-b run should pass; got:\n#{out_ab}"
    a_first = example_id_for('example defined in file a')
    b_first = example_id_for('example defined in file b')

    out_ba, status_ba = run_rspec(file_b, file_a)
    expect(status_ba.exitstatus).to eq(0), "b-then-a run should pass; got:\n#{out_ba}"
    a_second = example_id_for('example defined in file a')
    b_second = example_id_for('example defined in file b')

    expect(a_first).not_to be_nil
    expect(b_first).not_to be_nil
    expect(a_first).to eq(a_second), 'file-a example_id must not depend on rspec load order'
    expect(b_first).to eq(b_second), 'file-b example_id must not depend on rspec load order'
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/InstanceVariable, RSpec/BeforeAfterAll
