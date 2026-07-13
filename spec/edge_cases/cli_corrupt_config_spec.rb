# frozen_string_literal: true

# End-to-end graceful degradation of the `rspec-tracer` binary when
# the project's `.rspec-tracer` config itself is broken. The config is
# arbitrary user Ruby `load`ed while `lib/rspec_tracer.rb` boots, so a
# raise there happens OUTSIDE every sub-command's rescue. The binary
# must degrade to a one-line message + exit 1 with:
#   - no backtrace from the original error (CLI.load_tracer rescues
#     ScriptError as well as StandardError, because a config
#     SyntaxError is not a StandardError), and
#   - no secondary NoMethodError backtrace from the at_exit hook in
#     lib/rspec_tracer/defaults.rb, which registers before the module
#     body that defines `at_exit_behavior` runs (guarded via
#     `respond_to?`).
#
# Subprocess-driven because the failure mode lives at library load +
# process exit; it cannot be reproduced in-process once the spec
# suite has loaded rspec_tracer.

require 'open3'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'rspec-tracer binary with a corrupt project config' do
  def run_cli(config_body, *argv)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, '.rspec-tracer'), config_body)
      Open3.capture3(
        { 'BUNDLE_GEMFILE' => File.expand_path('../../Gemfile', __dir__) },
        'bundle', 'exec', 'ruby', File.expand_path('../../bin/rspec-tracer', __dir__), *argv,
        chdir: dir
      )
    end
  end

  it 'degrades a raising config to a one-line message and exit 1 for every sub-command path' do
    _out, err, status = run_cli("raise 'boom at config load'\n", 'cache:info')
    expect(status.exitstatus).to eq(1)
    expect(err).to include(
      'rspec-tracer: could not load configuration (.rspec-tracer): RuntimeError: boom at config load'
    )
    # No backtrace frames from the original raise, and no secondary
    # at_exit crash from the half-loaded module.
    expect(err).not_to include('load_local_config')
    expect(err).not_to include('at_exit_behavior')
    expect(err).not_to include('defaults.rb')
  end

  it 'degrades a config SyntaxError (not a StandardError) the same way' do
    _out, err, status = run_cli("def broken(\n", 'doctor')
    expect(status.exitstatus).to eq(1)
    expect(err).to include('rspec-tracer: could not load configuration (.rspec-tracer): SyntaxError:')
    expect(err).not_to include('load_local_config')
    expect(err).not_to include('at_exit_behavior')
  end

  it 'still answers --version without booting the config' do
    out, err, status = run_cli("raise 'boom at config load'\n", '--version')
    expect(status.exitstatus).to eq(0)
    expect(out).to match(/\Arspec-tracer \d/)
    expect(err).to eq('')
  end
end
# rubocop:enable RSpec/DescribeClass
