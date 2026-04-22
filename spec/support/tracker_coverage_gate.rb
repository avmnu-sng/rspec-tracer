# frozen_string_literal: true

# 100%-line + 100%-branch coverage gate scoped to the lib/rspec_tracer
# subdirectories listed in GATED_SUBDIRS. Legacy files get no retroactive
# pressure; mutation is the stronger signal for those (M8.3).
#
# Activation is per-file, keyed on the lib/spec pairing convention
# (lib/rspec_tracer/<subdir>/X.rb <-> spec/<subdir>/X_spec.rb). Running
# a single spec file only gates the lib module it covers; unrelated runs
# (e.g. spec/time_formatter_spec.rb) don't trigger at all.
module TrackerCoverageGate
  LIB_ROOT = File.expand_path('../../lib/rspec_tracer', __dir__)
  GATED_SUBDIRS = %w[tracker rails].freeze
  GATED_PREFIXES = GATED_SUBDIRS.map { |subdir| "#{File.join(LIB_ROOT, subdir)}/" }.freeze
  EPSILON = 0.001 # guard float equality of "100.0%"

  def self.install!
    return unless defined?(SimpleCov)

    # Kernel#at_exit runs LIFO; this hook is registered after
    # SimpleCov.start's own hook, so ours runs first and materializes
    # the result. SimpleCov's hook still runs afterward (idempotent).
    at_exit { TrackerCoverageGate.check! }
  end

  def self.check!
    return if skip?

    files = gated_files
    return if files.empty?

    failures = files.reject { |f| full_coverage?(f) }
    return if failures.empty?

    warn 'coverage gate FAIL (tracker files require 100% line + branch):'
    failures.each { |f| warn format_failure(f) }
    Kernel.exit(1)
  end

  # Under mutant, spec files are loaded for discovery but only a
  # targeted subset is executed — tracker files end up partially
  # covered by the `require` side-effect and the gate would fire inside
  # mutant's forked test subprocess, which mutant interprets as "the
  # mutation survived" (exit 1 ⟹ 0% mutation coverage). Same dogfood
  # spirit as spec_helper's RSPEC_TRACER_DISABLE guard in M2.5: the
  # gate is a full-suite assertion, not something mutant cares about.
  def self.skip?
    defined?(::Mutant) || ENV['RSPEC_TRACER_DISABLE'] == '1'
  end

  # Only the gated lib files whose paired spec file was actually in this
  # run's files_to_run list.
  def self.gated_files
    return [] unless defined?(RSpec) && RSpec.configuration

    SimpleCov.result.files.select do |f|
      gated_subdir_for(f.filename) && spec_ran_for?(f.filename)
    end
  end

  def self.spec_ran_for?(lib_file)
    subdir = gated_subdir_for(lib_file)
    return false if subdir.nil?

    basename = File.basename(lib_file, '.rb')
    suffix = "/spec/#{subdir}/#{basename}_spec.rb"
    RSpec.configuration.files_to_run.any? { |f| f.end_with?(suffix) }
  end

  def self.gated_subdir_for(lib_file)
    GATED_SUBDIRS.find.with_index do |_, index|
      lib_file.start_with?(GATED_PREFIXES[index])
    end
  end

  def self.full_coverage?(file)
    line_ok = file.covered_percent >= (100.0 - EPSILON)
    branch_ok = branch_percent(file) >= (100.0 - EPSILON)
    line_ok && branch_ok
  end

  def self.branch_percent(file)
    return 100.0 unless file.respond_to?(:branches_coverage_percent)

    pct = file.branches_coverage_percent
    pct.nil? ? 100.0 : pct
  end

  def self.format_failure(file)
    format('  %<file>s: line=%<l>.2f%% branch=%<b>.2f%%',
           file: file.filename, l: file.covered_percent, b: branch_percent(file))
  end
end
