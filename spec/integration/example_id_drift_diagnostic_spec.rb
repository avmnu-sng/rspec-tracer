# frozen_string_literal: true

# TEMPORARY diagnostic for the M5.1 parallel_tests id-drift
# investigation. Runs `parallel_rspec spec` twice (cold + warm) under
# RSPEC_TRACER_EXAMPLE_DIAG=1 which causes `RSpecTracer::Example.from`
# to emit every pre-MD5 `data` hash to STDERR. This spec captures both
# runs, parses the DIAG lines, groups by (file_name, line_number) +
# test_env_number, and fails loudly with a per-field diff when any
# field differs between cold and warm for the same example location.
#
# Remove once the root cause is fixed.

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'set'

module ExampleIdDriftDiag
  FIXTURE_ROOT = File.expand_path('../../benchmark/fixtures/ruby_app', __dir__)
  SCRUB_PATHS = %w[rspec_tracer_cache rspec_tracer_report rspec_tracer_coverage rspec_tracer.lock].freeze

  module_function

  def scrub!
    SCRUB_PATHS.each { |p| FileUtils.rm_rf(File.join(FIXTURE_ROOT, p)) }
  end

  def run_parallel_with_diag
    Bundler.with_unbundled_env do
      Open3.capture2e(
        { 'PARALLEL_TEST_GROUPS' => '2', 'RSPEC_TRACER_EXAMPLE_DIAG' => '1' },
        'bundle', 'exec', 'parallel_rspec', 'spec',
        chdir: FIXTURE_ROOT
      )
    end
  end

  def ensure_bundle!
    Bundler.with_unbundled_env do
      Dir.chdir(FIXTURE_ROOT) do
        unless system('bundle', 'check', out: File::NULL, err: File::NULL)
          out, status = Open3.capture2e('bundle', 'install', '--quiet')
          raise "bundle install failed:\n#{out}" unless status.success?
        end
      end
    end
  end
end

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/BeforeAfterAll, RSpec/ExampleLength
RSpec.describe 'Example.from id-drift diagnostic' do
  def parse_diag_lines(output)
    output.each_line.filter_map do |line|
      match = line.match(/EXAMPLE_DIAG:\s*(\{.*\})/)
      next unless match

      JSON.parse(match[1])
    rescue JSON::ParserError
      nil
    end
  end

  def group_by_location(entries)
    entries.each_with_object({}) do |entry, acc|
      key = [entry['file_name'], entry['line_number'], entry['test_env_number']]
      (acc[key] ||= []) << entry
    end
  end

  def diff_field(field, cold_value, warm_value)
    return nil if cold_value == warm_value

    "    #{field}: cold=#{cold_value.inspect} | warm=#{warm_value.inspect}"
  end

  before(:all) do
    ExampleIdDriftDiag.ensure_bundle!
    ExampleIdDriftDiag.scrub!
  end

  after(:all) { ExampleIdDriftDiag.scrub! }

  it 'emits identical data hashes for the same example across cold and warm parallel_rspec runs' do
    cold_out, cold_status = ExampleIdDriftDiag.run_parallel_with_diag
    expect(cold_status.exitstatus).to eq(0), "cold parallel_rspec failed:\n#{cold_out}"

    warm_out, warm_status = ExampleIdDriftDiag.run_parallel_with_diag
    expect(warm_status.exitstatus).to eq(0), "warm parallel_rspec failed:\n#{warm_out}"

    cold_entries = parse_diag_lines(cold_out)
    warm_entries = parse_diag_lines(warm_out)

    warn "=== DIAG: cold=#{cold_entries.size} warm=#{warm_entries.size} ruby=#{RUBY_VERSION} " \
         "rspec=#{Gem.loaded_specs['rspec-core']&.version} ==="

    cold_by_loc = group_by_location(cold_entries)
    warm_by_loc = group_by_location(warm_entries)

    all_keys = (cold_by_loc.keys | warm_by_loc.keys).sort
    report_lines = []

    all_keys.each do |key|
      cold_e = cold_by_loc[key]&.first
      warm_e = warm_by_loc[key]&.first

      if cold_e.nil? || warm_e.nil?
        report_lines << "LOCATION #{key.inspect} — present in only one run (cold=#{!cold_e.nil?}, warm=#{!warm_e.nil?})"
        next
      end

      field_diffs = cold_e.keys.filter_map do |field|
        next if field == 'example_id' # derived, will differ iff inputs differ

        diff_field(field, cold_e[field], warm_e[field])
      end

      unless field_diffs.empty?
        report_lines << "LOCATION #{key.inspect} (cold_id=#{cold_e['example_id']} warm_id=#{warm_e['example_id']})"
        report_lines.concat(field_diffs)
      end
    end

    if report_lines.any?
      warn '=== FIELD DRIFT DETECTED ==='
      report_lines.each { |line| warn line }
      warn '=== END DRIFT REPORT ==='
    end

    expect(report_lines).to(be_empty, -> { "drift detected:\n#{report_lines.join("\n")}" })
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/BeforeAfterAll, RSpec/ExampleLength
