# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'pathname'
require 'tmpdir'

# Verifies the contract of `task check:bundle:drift`
# (scripts/check_bundle_drift.rb): the script exits zero when every
# Gemfile resolves cleanly and non-zero when any one fails to
# resolve. We run the script directly (not via task) so the spec
# stays independent of the Taskfile wiring; a separate Taskfile
# test would just shell out to the same script.
#
# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations
# rubocop:disable RSpec/ExampleLength, RSpec/InstanceVariable
RSpec.describe 'scripts/check_bundle_drift.rb' do
  let(:script) { Pathname(__dir__).join('../../scripts/check_bundle_drift.rb').expand_path }

  def run_script(*gemfiles)
    Bundler.with_unbundled_env do
      Open3.capture2e('ruby', script.to_s, *gemfiles.map(&:to_s))
    end
  end

  context 'when all Gemfiles resolve cleanly' do
    it 'exits zero against a known-good fixture Gemfile' do
      gemfile = Pathname(__dir__).join('../../spec/fixtures/rails_app/Gemfile').expand_path
      output, status = run_script(gemfile)

      expect(status.exitstatus).to eq(0), "expected clean resolve; got:\n#{output}"
      expect(output).to include('ok')
    end
  end

  context 'when a Gemfile cannot resolve' do
    around do |example|
      Dir.mktmpdir do |dir|
        @broken_dir = Pathname(dir)
        example.run
      end
    end

    it 'exits non-zero and identifies the failing Gemfile' do
      broken_gemfile = @broken_dir.join('Gemfile')
      File.write(broken_gemfile, <<~GEMFILE)
        # frozen_string_literal: true
        source 'https://rubygems.org'
        # An unsatisfiable version constraint - rails has no 999.x line.
        gem 'rails', '~> 999.0'
      GEMFILE

      output, status = run_script(broken_gemfile)

      expect(status.exitstatus).not_to eq(0)
      expect(output).to include('FAIL')
      expect(output).to match(/failed to resolve/i)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations
# rubocop:enable RSpec/ExampleLength, RSpec/InstanceVariable
