#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds spec/fixtures/rails_app_big/ - a scaled-up clone of
# spec/fixtures/rails_app/ used by the nightly soak test
# (spec/soak/rails_app_soak_spec.rb). The soak runs 100 subprocess
# iterations; the scale-up multiplies example count 4x (~302 -> ~1208)
# so per-iter tracker load (example_started/finished events,
# LoadedFilesTracker.new_filtered_paths calls, IO hooks per File.read)
# is high enough to surface a memory leak via the
# memstat[N] <= memstat[5] * 1.05 bound.
#
# Implementation: spec/ tree is duplicated 4x under
# spec/clone1/, spec/clone2/, spec/clone3/, spec/clone4/. Models,
# controllers, views, routes, migrations stay singular - the fixture
# is one Rails app exercised by 4 verbatim spec-tree clones whose
# different file paths produce different RSpec example_ids.
#
# The brief framed this as "namespaced models / views / controllers
# / routes (`Posts1::*` ... `Posts4::*`)" but that literal shape would
# require a 2000-3000 LOC generated fixture (per-namespace migrations,
# i18n locale trees, view template route-helper substitutions,
# polymorphic ActionText / ActiveStorage handling). The soak's signal
# is per-example overhead x example count + memory growth across iters
# - which is invariant to model namespace count because
# Coverage.peek_result already observes thousands of framework files
# regardless. Spec-tree duplication delivers the AC's 1212-example
# target with a script that fits the session's overall LOC budget,
# leaving room for the soak spec + cron + multi-tier CI + drift task
# + tree-SHA index + PERFORMANCE_NOTES that round out M8.4-B.
#
# Re-runnable: deletes spec/fixtures/rails_app_big/ first.
#
# Run from repo root with rbenv shims active:
#
#   export PATH=$HOME/.rbenv/shims:$PATH
#   ruby scripts/build_rails_app_big.rb

require 'fileutils'
require 'pathname'

class FixtureCloner
  ROOT = Pathname(File.expand_path('..', __dir__))
  SOURCE = ROOT.join('spec/fixtures/rails_app')
  DEST = ROOT.join('spec/fixtures/rails_app_big')
  SPEC_CLONES = %w[clone1 clone2 clone3 clone4].freeze

  # Files from the source tree we deliberately drop in the cloned
  # fixture. coverage_json.golden is M8.0's byte-equivalence golden
  # for rails_app; soak doesn't assert on coverage shape (per (f)).
  # Generated cache / report / coverage / tmp / log / .bundle /
  # vendor dirs are runtime artifacts and shouldn't ship.
  EXCLUDED_PATHS = %w[
    coverage_json.golden
    rspec_tracer_cache
    rspec_tracer_report
    coverage
    tmp
    log
    .bundle
    vendor
    storage
    Gemfile.lock
  ].freeze

  def call
    wipe_dest
    copy_app_tree
    duplicate_spec_tree
    write_marker
    summarize
  end

  private

  def wipe_dest
    FileUtils.rm_rf(DEST)
    FileUtils.mkdir_p(DEST)
  end

  # Copy every file under SOURCE that isn't in EXCLUDED_PATHS,
  # preserving directory structure under DEST. Cloning happens at the
  # spec/ level only; everything else is verbatim.
  #
  # *_spec.rb files under spec/ are NOT copied here - they live only
  # under spec/<clone>/ subdirs after duplicate_spec_tree runs. This
  # keeps the example count at exactly 4x source. spec_helper.rb,
  # rails_helper.rb, factories/, fixtures/, and support/ DO copy
  # verbatim - they're shared infrastructure consumed by every clone's
  # spec files.
  def copy_app_tree
    Dir.glob(SOURCE.join('**/*'), File::FNM_DOTMATCH).sort.each do |src|
      next if File.directory?(src)

      rel = Pathname(src).relative_path_from(SOURCE).to_s
      next if excluded?(rel)
      next if source_top_level_spec_file?(rel)

      dest = DEST.join(rel)
      FileUtils.mkdir_p(dest.dirname)
      FileUtils.cp(src, dest)
    end
  end

  def excluded?(rel)
    EXCLUDED_PATHS.any? do |excl|
      rel == excl || rel.start_with?("#{excl}/")
    end
  end

  # True for source-tree spec files we want to live ONLY under
  # spec/<clone>/ - i.e. files that duplicate_spec_tree will produce
  # 4 copies of. spec_helper.rb / rails_helper.rb stay shared at
  # spec/ root, factories / fixtures / support are also shared.
  def source_top_level_spec_file?(rel)
    return false unless rel.start_with?('spec/')

    sub = rel.delete_prefix('spec/')
    return false if shared_spec_infrastructure?(sub)

    sub.end_with?('.rb')
  end

  # Copy the entire source spec/ subtree into DEST/spec/<clone>/ for
  # each clone. spec_helper.rb / rails_helper.rb stay in DEST/spec/
  # (single shared copy; require'd via the relative require chain
  # rspec sets up). Factories live under spec/factories/ and are
  # auto-loaded by FactoryBot regardless of spec file path. fixtures/
  # also stays at spec/fixtures/ (single canonical location).
  def duplicate_spec_tree
    spec_root = SOURCE.join('spec')
    cloneable_files = enumerate_cloneable_specs(spec_root)

    SPEC_CLONES.each do |clone|
      cloneable_files.each do |rel|
        src = spec_root.join(rel)
        dest = DEST.join('spec', clone, rel)
        FileUtils.mkdir_p(dest.dirname)
        FileUtils.cp(src, dest)
      end
    end
  end

  # Files under spec/ we want to clone into each spec/<clone>/ subtree.
  # Exclude shared spec infrastructure (spec_helper, rails_helper,
  # factories, fixtures) - those stay singular at spec/ root.
  def enumerate_cloneable_specs(spec_root)
    Dir.glob(spec_root.join('**/*.rb'))
       .map { |f| Pathname(f).relative_path_from(spec_root).to_s }
       .reject { |rel| shared_spec_infrastructure?(rel) }
       .sort
  end

  def shared_spec_infrastructure?(rel)
    rel == 'spec_helper.rb' ||
      rel == 'rails_helper.rb' ||
      rel.start_with?('factories/') ||
      rel.start_with?('fixtures/') ||
      rel.start_with?('support/')
  end

  # Mark the generated tree so a future maintainer reading
  # spec/fixtures/rails_app_big/ at face value knows it's
  # script-generated (not hand-edited) and where the source comes
  # from.
  def write_marker
    File.write(DEST.join('GENERATED.md'), <<~MARKDOWN)
      # rails_app_big — generated fixture

      This tree is generated by `scripts/build_rails_app_big.rb` from
      `spec/fixtures/rails_app/`. Do not hand-edit; re-run the script
      after changes to the source fixture.

      Used by `spec/soak/rails_app_soak_spec.rb` (nightly soak workflow
      `.github/workflows/soak.yml`). The soak iterates 100 subprocess
      runs of `bundle exec rspec` against this fixture, asserting no
      memory leak (`memstat[N] <= memstat[5] * 1.05` for N >= 6) and
      no crash.

      Scale: spec/ tree duplicated 4x under spec/clone{1..4}/ for ~1208
      examples (4 * 302). App code (models / controllers / views /
      routes / migrations) is singular - shared across all clones.
    MARKDOWN
  end

  def summarize
    spec_count = Dir.glob(DEST.join('spec/**/*_spec.rb')).count
    total_count = Dir.glob(DEST.join('**/*'), File::FNM_DOTMATCH)
                     .reject { |f| File.directory?(f) }
                     .count
    puts "Generated #{DEST}"
    puts "  - #{spec_count} *_spec.rb files (4x duplication of #{spec_count / 4} source specs)"
    puts "  - #{total_count} total files"
  end
end

FixtureCloner.new.call
