# frozen_string_literal: true

# End-to-end regression for #196: example_id stability across runs.
#
# `example_id` (the MD5 RSpecTracer::Example.from produces) used to
# hash `example_group.name` — RSpec's generated class name, which
# carries a load-order-dependent `_2` / `_3` disambiguator suffix
# when two spec files share a describe-block name. Two files both
# `RSpec.describe 'Nice'` produced different example_ids depending
# on which file rspec loaded first, silently invalidating the cache
# and breaking the failed/pending/flaky always-re-run guarantees.
# Line numbers in the payload had the same effect: a no-op blank-line
# edit flipped the id.
#
# This spec drives the ruby_app fixture with bespoke temp spec files
# (the flaky_detection_spec.rb / run_reason_persistence_spec.rb
# pattern) and walks the documented stability contract — "rename =
# new identity; restructure = same identity":
#
#   1. multi-file same-`describe` name, both rspec load orders -> the
#      same `it` keeps its id (the headline #196 bug)
#   2. no-op blank-line edit above an example -> id unchanged
#   3. spec file renamed -> id changes (rename = new identity)
#   4. one shared example included twice in the same host -> the two
#      inclusions now collide (the :LINE strip is what makes them
#      collide) and duplicate detection fires
#   5. two identically-described plain examples in one group ->
#      duplicate detection fires (line_number no longer false-splits)
#   6. class describe (RSpec.describe SomeClass) -> stable id
#   7. anonymous describe (RSpec.describe do ... end) -> valid,
#      distinct ids; full_description disambiguates

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe 'example_id stability across runs (issue #196)' do
  let(:fixture_root) { File.expand_path('../../benchmark/fixtures/ruby_app', __dir__) }
  let(:cache_dir)    { File.join(fixture_root, 'rspec_tracer_cache') }
  let(:report_dir)   { File.join(fixture_root, 'rspec_tracer_report') }
  let(:coverage_dir) { File.join(fixture_root, 'rspec_tracer_coverage') }
  let(:temp_glob)    { File.join(fixture_root, 'spec', 'rt_idstab_*.rb') }

  around do |example|
    Bundler.with_unbundled_env do
      cleanup
      example.run
    ensure
      cleanup
    end
  end

  before { ensure_bundle_installed! }

  def cleanup
    FileUtils.rm_rf([cache_dir, report_dir, coverage_dir])
    Dir[temp_glob].each { |f| FileUtils.rm_f(f) }
  end

  def ensure_bundle_installed!
    Dir.chdir(fixture_root) do
      next if system('bundle check > /dev/null 2>&1')

      install_out, install_status = Open3.capture2e('bundle', 'install', '--quiet')
      raise "bundle install failed in #{fixture_root}:\n#{install_out}" unless install_status.success?
    end
  end

  # Writes a spec file under the fixture's spec/ dir; returns the
  # fixture-relative path for use as a positional rspec arg.
  def write_spec(basename, body)
    rel = File.join('spec', "rt_idstab_#{basename}.rb")
    File.write(File.join(fixture_root, rel), body)
    rel
  end

  # Cold run: caches are scrubbed first so every invocation computes
  # the identity hash fresh — a warm run would skip the example and
  # echo the seeded id, testing cache persistence rather than
  # identity computation. Positional spec_files also let a test pin
  # the rspec file LOAD ORDER. RSPEC_TRACER_DISABLE is deleted from
  # the child env so a parent-runner setting can't leak in.
  def run_rspec_cold(*spec_files)
    FileUtils.rm_rf([cache_dir, report_dir, coverage_dir])
    Open3.capture2e(
      { 'RSPEC_TRACER_DISABLE' => nil },
      'bundle', 'exec', 'rspec', '--no-color', *spec_files, chdir: fixture_root
    )
  end

  def report_payload
    JSON.parse(File.read(File.join(report_dir, 'report.json'), encoding: 'UTF-8'))
  end

  def example_id_for(description_substring)
    report_payload['reports']['all_examples']
      .find { |e| e['description']&.include?(description_substring) }
      &.fetch('id')
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

    _, status_ab = run_rspec_cold(file_a, file_b)
    expect(status_ab.exitstatus).to eq(0), 'a-then-b run should pass'
    a_first = example_id_for('example defined in file a')
    b_first = example_id_for('example defined in file b')

    _, status_ba = run_rspec_cold(file_b, file_a)
    expect(status_ba.exitstatus).to eq(0), 'b-then-a run should pass'
    a_second = example_id_for('example defined in file a')
    b_second = example_id_for('example defined in file b')

    expect(a_first).not_to be_nil
    expect(b_first).not_to be_nil
    expect(a_first).to eq(a_second), 'file-a example_id must not depend on rspec load order'
    expect(b_first).to eq(b_second), 'file-b example_id must not depend on rspec load order'
  end

  it 'keeps an example_id stable across a no-op line-shifting edit' do
    body = <<~RUBY
      RSpec.describe 'Line Shift Fixture' do
        it 'identity case: stable under blank-line insertion' do
          expect(1).to eq(1)
        end
      end
    RUBY
    spec = write_spec('line_shift_spec', body)
    run_rspec_cold(spec)
    before_id = example_id_for('stable under blank-line insertion')

    # Three blank lines above the describe — a pure cosmetic edit.
    write_spec('line_shift_spec', "\n\n\n#{body}")
    run_rspec_cold(spec)
    after_id = example_id_for('stable under blank-line insertion')

    expect(before_id).not_to be_nil
    expect(before_id).to eq(after_id)
  end

  it 'changes the example_id when the spec file is renamed (rename = new identity)' do
    body = <<~RUBY
      RSpec.describe 'Rename Fixture' do
        it 'identity case: id tracks the file name' do
          expect(1).to eq(1)
        end
      end
    RUBY
    original = write_spec('rename_before_spec', body)
    run_rspec_cold(original)
    before_id = example_id_for('id tracks the file name')

    renamed = write_spec('rename_after_spec', body)
    FileUtils.rm_f(File.join(fixture_root, original))
    run_rspec_cold(renamed)
    after_id = example_id_for('id tracks the file name')

    expect(before_id).not_to be_nil
    expect(after_id).not_to be_nil
    expect(before_id).not_to eq(after_id)
  end

  it 'flags a shared example included twice in the same host as a duplicate' do
    spec = write_spec('shared_dup_spec', <<~RUBY)
      RSpec.shared_examples 'an identity-stable shared example' do
        it 'identity case: shared example body' do
          expect(true).to be(true)
        end
      end

      RSpec.describe 'Shared Inclusion Host' do
        it_behaves_like 'an identity-stable shared example'
        it_behaves_like 'an identity-stable shared example'
      end
    RUBY

    out, = run_rspec_cold(spec)

    expect(out).to match(/\d+ duplicate example\(s\) across \d+ identity hash/)
  end

  it 'flags two identically-described examples in one group as a duplicate' do
    spec = write_spec('plain_dup_spec', <<~RUBY)
      RSpec.describe 'Plain Duplicate Host' do
        it 'identity case: same description twice' do
          expect(1).to eq(1)
        end

        it 'identity case: same description twice' do
          expect(2).to eq(2)
        end
      end
    RUBY

    out, = run_rspec_cold(spec)

    expect(out).to match(/\d+ duplicate example\(s\) across \d+ identity hash/)
  end

  it 'produces a stable id for a class describe (RSpec.describe SomeClass)' do
    spec = write_spec('class_describe_spec', <<~RUBY)
      RSpec.describe String do
        it 'identity case: class-described example' do
          expect(described_class).to eq(String)
        end
      end
    RUBY

    _, first_status = run_rspec_cold(spec)
    expect(first_status.exitstatus).to eq(0)
    first_id = example_id_for('class-described example')

    _, second_status = run_rspec_cold(spec)
    expect(second_status.exitstatus).to eq(0)
    second_id = example_id_for('class-described example')

    expect(first_id).to match(/\A[0-9a-f]{32}\z/)
    expect(first_id).to eq(second_id)
  end

  it 'produces distinct ids for examples under an anonymous describe' do
    spec = write_spec('anonymous_describe_spec', <<~RUBY)
      RSpec.describe do
        it 'identity case: anonymous example one' do
          expect(1).to eq(1)
        end

        it 'identity case: anonymous example two' do
          expect(2).to eq(2)
        end
      end
    RUBY

    _, status = run_rspec_cold(spec)

    expect(status.exitstatus).to eq(0)
    one_id = example_id_for('anonymous example one')
    two_id = example_id_for('anonymous example two')
    expect(one_id).to match(/\A[0-9a-f]{32}\z/)
    expect(two_id).to match(/\A[0-9a-f]{32}\z/)
    expect(one_id).not_to eq(two_id)
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
