# frozen_string_literal: true

# End-to-end stdout purity of the `rspec-tracer` binary when the
# project's `.rspec-tracer` uses a deprecated 1.x DSL option. The
# deprecation shims (`reports_s3_path`, `use_local_aws`) fire a
# one-time `logger.warn` while the config loads, BEFORE sub-command
# dispatch, and in a fresh CLI process "one-time" means every
# invocation. The logger's default destination is stdout, so before
# the CLI rebound `Logger.default_out` around library boot the
# warning printed AHEAD of the `blast-radius --json` document and
# broke `... --json | jq` deterministically for exactly the users the
# compat shims exist to support.
#
# Subprocess-driven because the failure mode lives at library load;
# it cannot be reproduced in-process once the spec suite has loaded
# rspec_tracer (a second `require 'rspec_tracer'` is a no-op, so the
# config-load window never reopens).

require 'json'
require 'open3'
require 'set'
require 'tmpdir'

require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'
require 'rspec_tracer/storage/schema'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'rspec-tracer binary with a deprecated-DSL project config' do
  def seed_cache(dir)
    snapshot = RSpecTracer::Storage::Snapshot.empty(
      schema_version: RSpecTracer::Storage::Schema::CURRENT, run_id: 'run_purity'
    )
    snapshot.all_examples = {
      'spec/calc_spec.rb[1:1]' => {
        'example_id' => 'spec/calc_spec.rb[1:1]',
        'full_description' => 'Calc adds',
        'rerun_file_name' => './spec/calc_spec.rb',
        'rerun_line_number' => 7
      }
    }
    snapshot.reverse_dependency = { '/lib/calc.rb' => Set.new(['spec/calc_spec.rb[1:1]']) }
    RSpecTracer::Storage::JsonBackend.new(cache_path: File.join(dir, 'rspec_tracer_cache')).save_graph(
      snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT
    )
  end

  def run_cli(config_body, *argv)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, '.rspec-tracer'), config_body)
      seed_cache(dir)
      Open3.capture3(
        {
          'BUNDLE_GEMFILE' => File.expand_path('../../Gemfile', __dir__),
          # Deleted (nil) so the subprocess cache_path stays exactly
          # <dir>/rspec_tracer_cache; either var appends a scope
          # segment and would miss the seeded cache.
          'TEST_SUITE_ID' => nil,
          'TEST_ENV_NUMBER' => nil
        },
        'bundle', 'exec', 'ruby', File.expand_path('../../bin/rspec-tracer', __dir__), *argv,
        chdir: dir
      )
    end
  end

  it 'keeps `blast-radius --json` stdout strictly parseable with the deprecation warning on stderr' do
    config = <<~CONFIG
      RSpecTracer.configure do
        reports_s3_path 's3://bucket/prefix'
      end
    CONFIG
    out, err, status = run_cli(config, 'blast-radius', '--json', 'lib/calc.rb')
    expect(status.exitstatus).to eq(0)
    # Strict parse over the WHOLE stdout capture is the contract
    # check: it raises if the deprecation line (or anything else)
    # precedes or follows the single JSON document.
    payload = JSON.parse(out)
    expect(payload['files'].first).to include('status' => 'tracked', 'example_count' => 1)
    expect(err).to include('rspec-tracer deprecation')
    expect(err).to include('reports_s3_path')
  end

  it 'keeps the stderr binding when the config resets log_level between deprecated DSL calls' do
    # `Configuration#log_level` nils the memoized logger instance; the
    # next deprecation warning constructs a fresh logger mid-load,
    # which must still pick up the CLI's stderr default.
    config = <<~CONFIG
      RSpecTracer.configure do
        reports_s3_path 's3://bucket/prefix'
        log_level :debug
        use_local_aws true
      end
    CONFIG
    out, err, status = run_cli(config, 'blast-radius', '--json', 'lib/calc.rb')
    expect(status.exitstatus).to eq(0)
    expect { JSON.parse(out) }.not_to raise_error
    expect(err).to include('reports_s3_path')
    expect(err).to include('use_local_aws')
  end
end
# rubocop:enable RSpec/DescribeClass
