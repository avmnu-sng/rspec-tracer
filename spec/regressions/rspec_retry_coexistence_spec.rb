# frozen_string_literal: true

# Coexistence smoke spec for rspec-retry + rspec-tracer.
#
# rspec-retry (https://github.com/NoRedInk/rspec-retry) wraps
# RSpec::Core::Example via Module#prepend to retry failing examples up
# to N times. rspec-tracer's M5.1 hook chain prepends
# RSpec::Core::Runner (RunnerHook) and RSpec::Core::Reporter
# (ReporterHook) - DIFFERENT MRO points than rspec-retry's prepend on
# Example. The two extensions should compose without conflict.
#
# This spec verifies the smoke contract:
#   1. Both gems load alongside each other without raising at boot.
#   2. A passing example with `retry: N` metadata runs to completion.
#   3. The rspec-tracer cache writes successfully (run_id manifest +
#      all_examples.json present after the run).
#
# Drives a subprocess inside `Bundler.with_unbundled_env` + a tmpdir
# CWD so the inline test spec doesn't pollute the project's
# rspec_tracer_cache + the outer rspec process never loads
# rspec-retry's Module#prepend (which would otherwise affect every
# subsequent in-process spec). The outer Gemfile carries rspec-retry
# in the :development group (require: false default) so the
# subprocess can require it on demand.
#
# If a real conflict surfaces here, file a follow-up issue - smoke
# specs are non-blocking. The cache-state assertion (not just
# exit-status) is the load-bearing check; exit-status-only checks
# mask cache-persistence bugs.

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe 'rspec-retry coexistence (smoke)' do
  let(:project_root) { File.expand_path('../..', __dir__) }
  let(:gemfile_path) { File.join(project_root, 'Gemfile') }

  let(:inline_spec_body) do
    <<~RUBY
      require "rspec_tracer"
      RSpecTracer.start

      require "rspec/retry"

      RSpec.configure do |config|
        config.verbose_retry = false
        config.display_try_failure_messages = false
      end

      RSpec.describe "rspec-retry composes with rspec-tracer" do
        it "passes on first try with retry metadata", retry: 2 do
          expect(true).to be(true)
        end

        it "exercises the prepend chain for a second example", retry: 1 do
          expect(2 + 2).to eq(4)
        end
      end
    RUBY
  end

  it 'composes the prepend chains without raising and writes a cache' do
    Dir.mktmpdir do |dir|
      spec_path = File.join(dir, 'retry_smoke_spec.rb')
      File.write(spec_path, inline_spec_body)

      out, status = Bundler.with_unbundled_env do
        env = {
          'RSPEC_TRACER' => '1',
          'BUNDLE_GEMFILE' => gemfile_path
        }
        Open3.capture2e(env, 'bundle', 'exec', 'rspec', '--no-color', spec_path,
                        chdir: dir)
      end

      expect(status.success?).to(be(true), "rspec-retry coexistence subprocess failed:\n#{out}")

      cache_dir = File.join(dir, 'rspec_tracer_cache')
      manifest_path = File.join(cache_dir, 'last_run.json')
      expect(File).to(exist(manifest_path),
                      "expected rspec-tracer cache manifest at #{manifest_path}; got dir contents: " \
                      "#{Dir.exist?(cache_dir) ? Dir.children(cache_dir).inspect : '(no cache dir)'}")

      manifest = JSON.parse(File.read(manifest_path))
      run_id = manifest.fetch('run_id')
      all_examples = JSON.parse(File.read(File.join(cache_dir, run_id, 'all_examples.json')))

      expect(all_examples.size).to(eq(2),
                                   "expected 2 registered examples, got #{all_examples.size}: " \
                                   "#{all_examples.values.map { |m| m['description'] }.inspect}")
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
