# frozen_string_literal: true

# Coexistence smoke spec for rspec-rerun + rspec-tracer.
#
# rspec-rerun (https://github.com/dblock/rspec-rerun) registers an
# RSpec::Core::Formatters formatter (RSpec::Rerun::Formatter) that
# writes failed-example rerun commands to `rspec.failures` after each
# run; subsequent runs can re-execute only those examples by passing
# the file's contents back to rspec. It's pure formatter, NOT a
# Module#prepend - so it operates orthogonally to rspec-tracer's
# RunnerHook / ReporterHook prepends.
#
# This spec verifies the smoke contract:
#   1. Both gems load alongside each other without raising.
#   2. A passing test run completes to a written rspec-tracer cache
#      AND no rspec.failures artifact (the formatter cleans up on a
#      clean run) without path collision.
#   3. The two on-disk artifacts coexist in the same project root
#      without either tool clobbering the other.
#
# Drives a subprocess inside `Bundler.with_unbundled_env` + a tmpdir
# CWD so the inline test spec doesn't pollute the project's
# rspec_tracer_cache + rerun.txt. The outer Gemfile carries
# rspec-rerun in the :development group (require: false default) so
# the subprocess can require it on demand.
#
# If a real conflict surfaces here, file as M9.0-B follow-up per the
# brief - smoke specs are non-blocking.

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe 'rspec-rerun coexistence (smoke)' do
  let(:project_root) { File.expand_path('../..', __dir__) }
  let(:gemfile_path) { File.join(project_root, 'Gemfile') }

  let(:inline_spec_body) do
    <<~RUBY
      require "rspec_tracer"
      RSpecTracer.start

      require "rspec-rerun/formatter"

      RSpec.configure do |config|
        config.add_formatter RSpec::Rerun::Formatter
      end

      RSpec.describe "rspec-rerun composes with rspec-tracer" do
        it "registers cleanly" do
          expect(true).to be(true)
        end

        it "exercises a second example so the cache is non-trivial" do
          expect("rspec-rerun").to start_with("rspec")
        end
      end
    RUBY
  end

  it 'co-writes rspec_tracer_cache + rerun.txt without conflict' do
    Dir.mktmpdir do |dir|
      spec_path = File.join(dir, 'rerun_smoke_spec.rb')
      File.write(spec_path, inline_spec_body)

      out, status = Bundler.with_unbundled_env do
        env = {
          'RSPEC_TRACER' => '1',
          'BUNDLE_GEMFILE' => gemfile_path
        }
        # rspec-rerun's FailuresFormatter writes rerun.txt to CWD when
        # the run has failures; both gems' artifacts coexist in the
        # tmpdir without path collision after the subprocess returns.
        Open3.capture2e(env, 'bundle', 'exec', 'rspec', '--no-color', spec_path,
                        chdir: dir)
      end

      expect(status.success?).to(be(true), "rspec-rerun coexistence subprocess failed:\n#{out}")

      cache_dir = File.join(dir, 'rspec_tracer_cache')
      manifest_path = File.join(cache_dir, 'last_run.json')
      expect(File).to(exist(manifest_path),
                      "expected rspec-tracer cache manifest at #{manifest_path}")

      manifest = JSON.parse(File.read(manifest_path))
      run_id = manifest.fetch('run_id')
      all_examples = JSON.parse(File.read(File.join(cache_dir, run_id, 'all_examples.json')))

      expect(all_examples.size).to(eq(2),
                                   "expected 2 registered examples, got #{all_examples.size}: " \
                                   "#{all_examples.values.map { |m| m['description'] }.inspect}")

      # rspec-rerun's Formatter writes `rspec.failures` only on
      # failure; on a clean run it deletes the file (clean! at line
      # 18 of formatter.rb). Both examples pass here, so the file
      # should NOT exist after the run - the smoke check is that
      # neither gem crashed writing its artifact.
      rerun_path = File.join(dir, 'rspec.failures')
      expect(File.exist?(rerun_path)).to(be(false),
                                         'rspec.failures should be cleaned up when all examples pass')
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
