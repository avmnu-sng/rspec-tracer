# frozen_string_literal: true

# End-to-end regression for #195's two related bugs:
#
#   (a) RSpecTracer.start crashed with
#       `RuntimeError: coverage measurement is already setup`
#       when the user pre-started `::Coverage` to opt into branch
#       coverage. setup_coverage now mirrors
#       Engine#ensure_coverage_started's `Coverage.running?` guard
#       (+ rescue) so both entry points agree.
#
#   (b) Standalone path was lines-only (`bare Coverage.start`). The
#       new `coverage_modes` DSL threads any combination of
#       `[:lines, :branches, :methods, :oneshot_lines, :eval]`
#       through to `::Coverage.start(**modes)` so users can opt into
#       branches without SimpleCov.
#
# Both scenarios drive a one-off Ruby subprocess against the
# ruby_app fixture's Gemfile (which depends on rspec-tracer via
# `path:`); subprocess isolation guarantees no leak from the parent
# test process's already-running Coverage.

require 'bundler'
require 'fileutils'
require 'open3'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe 'standalone Coverage modes integration (issue #195)' do
  let(:fixture_root) { File.expand_path('../../benchmark/fixtures/ruby_app', __dir__) }
  let(:script_path)  { File.join(fixture_root, 'coverage_modes_probe.rb') }

  around do |example|
    Bundler.with_unbundled_env do
      example.run
    ensure
      FileUtils.rm_f(script_path)
    end
  end

  def ensure_bundle_installed!
    Dir.chdir(fixture_root) do
      next if system('bundle check > /dev/null 2>&1')

      install_out, install_status = Open3.capture2e('bundle', 'install', '--quiet')
      raise "bundle install failed in #{fixture_root}:\n#{install_out}" unless install_status.success?
    end
  end

  before { ensure_bundle_installed! }

  it 'does not crash when the user pre-starts Coverage with branches' do
    File.write(script_path, <<~RUBY)
      require 'coverage'
      ::Coverage.start(lines: true, branches: true)

      require 'rspec_tracer'

      # setup_coverage was the crash point on a pre-started Coverage.
      # The Coverage.running? guard short-circuits before the bare
      # Coverage.start re-call. We drive setup_coverage directly so
      # the test doesn't depend on the full RSpec hook install chain.
      RSpecTracer.send(:setup_coverage)

      puts 'OK'
    RUBY

    out, status = Open3.capture2e('bundle', 'exec', 'ruby', 'coverage_modes_probe.rb', chdir: fixture_root)
    expect(status.exitstatus).to eq(0), "subprocess failed:\n#{out}"
    expect(out).to include('OK')
  end

  it 'threads coverage_modes :branches through to Coverage.start on the standalone path' do
    File.write(script_path, <<~RUBY)
      require 'rspec_tracer'

      RSpecTracer.coverage_modes(%i[lines branches])
      RSpecTracer.send(:setup_coverage)

      # Coverage was started AFTER rspec-tracer loaded, so the
      # rspec-tracer lib files are not tracked. Load + exercise the
      # fixture's calculator AFTER the start so its `if b.zero?`
      # branches yield branch entries in Coverage.peek_result.
      require_relative 'app/calculator'
      Calculator.new.divide(10, 2)

      require 'coverage'
      result = ::Coverage.peek_result
      any_branch = result.any? { |_path, data| data.is_a?(::Hash) && data.key?(:branches) }
      puts(any_branch ? 'BRANCHES_TRACKED' : 'NO_BRANCHES')
    RUBY

    out, status = Open3.capture2e('bundle', 'exec', 'ruby', 'coverage_modes_probe.rb', chdir: fixture_root)
    expect(status.exitstatus).to eq(0), "subprocess failed:\n#{out}"
    expect(out).to include('BRANCHES_TRACKED')
  end

  it 'omits branches from Coverage.peek_result when coverage_modes is not set' do
    File.write(script_path, <<~RUBY)
      require 'rspec_tracer'

      RSpecTracer.send(:setup_coverage)

      require_relative 'app/calculator'
      Calculator.new.divide(10, 2)

      require 'coverage'
      result = ::Coverage.peek_result
      branches_present = result.any? { |_path, data| data.is_a?(::Hash) && data.key?(:branches) }
      puts(branches_present ? 'BRANCHES_TRACKED' : 'NO_BRANCHES')
    RUBY

    out, status = Open3.capture2e('bundle', 'exec', 'ruby', 'coverage_modes_probe.rb', chdir: fixture_root)
    expect(status.exitstatus).to eq(0), "subprocess failed:\n#{out}"
    expect(out).to include('NO_BRANCHES')
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
