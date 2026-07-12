# frozen_string_literal: true

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'pathname'

# Soak test against pinned-SHA real-world Rails+RSpec projects:
# Solidus / Refinery / Spree. Each project's pin lives at
# .github/sha-pins/<project>.txt (sha + tag + license_sha256);
# the workflow / `task soak:fixture:<project>` clones at the pinned
# SHA, injects rspec-tracer into the project's Gemfile, bundles,
# and db-prepares. This spec consumes the prepped fixture: subprocess
# per iter, deterministic-seeded random file mutation rotation
# through 9 kinds, asserts memstat[N] <= memstat[5] * 1.05 for
# N >= 6.
#
# Driven by env:
#   SOAK_PROJECT       - solidus | refinery | spree (REQUIRED)
#   SOAK_FIXTURE_ROOT  - cloned project path
#                        (default: tmp/soak-fixtures/<project>)
#   SOAK_ITERATIONS    - iter count override
#                        (default: solidus=50, refinery=100, spree=20 per shard)
#   SOAK_SHARD         - per-cell shard index (1-indexed; unset for
#                        unsharded cells). Used by the workflow to split
#                        Spree across 2 matrix cells (`spree-shard-1`,
#                        `spree-shard-2`) with disjoint mutation-seed
#                        slices so the combined shards cover what a
#                        single-cell N*ITERATIONS run would have. Empty
#                        = no offset (legacy semantics).
#   SOAK_WARMUP_ITERS  - warm-up baseline iter (default: 5)
#   SOAK_MEMORY_BOUND  - growth bound vs warm-up (default: 1.20)
#
# Run via:
#   task soak:fixture:<project>  # one-time clone + bundle + db prep
#   task soak:smoke:<project>    # 10 iters - pre-PR parity proxy
#   task soak:full:<project>     # full per-project iter count - cron
#
# Excluded from the default rspec sweep via .rspec --exclude-pattern.
#
# Iteration mechanism: subprocess per iter via Open3.capture2e (M5.1
# cold-subprocess test-isolation contract preserved per
# feedback_jruby_ci_subprocess_floor); NO fork() in the spec - if
# ever introduced, the child must Process.exit!(0) per
# feedback_simplecov_fork_poisoning. Open3 is wrapped in
# Bundler.with_unbundled_env per
# feedback_bundler_unbundled_env_for_fixture_subprocess - the outer
# `bundle exec rspec` leaks RUBYOPT=-rbundler/setup + BUNDLE_GEMFILE
# etc. into the child; with_unbundled_env clears those so the child
# resolves against the fixture's Gemfile cleanly.
#
# Cache state assertions only; no coverage.json byte-equivalence
# (M8.0 domain - would require CI= empty pinning per
# feedback_rails_eager_load_coverage_timing). Cleanup-guard hygiene
# via spec/support/integration_cleanup.rb (M8.2).
#
# Per-project layout differs significantly:
#
# - Solidus: monorepo at clone root with one Gemfile; engines (admin
#   /api/backend/core/sample/legacy_promotions/promotions) live as
#   subdirs each with its own spec/. Soak runs one engine (api -
#   smallest) for fast iters.
# - Refinery: monorepo at clone root with one Gemfile + dummy_app
#   gen via `rake refinery:testing:dummy_app`. Specs at root.
# - Spree: monorepo at clone root, but the actual gem source is at
#   spree/ (subdir). Spree's Gemfile + Rakefile live at spree/.
#   Soak runs spree/core engine.

REPO_ROOT = Pathname(__dir__).parent.parent.expand_path
SOAK_TMP = REPO_ROOT.join('tmp/soak')
MEMSTAT_AT_EXIT = REPO_ROOT.join('spec/soak/memstat_at_exit.rb')
SOAK_START = REPO_ROOT.join('spec/soak/soak_start.rb')

require REPO_ROOT.join('spec/support/integration_cleanup').to_s

# Per-project invocation config. `gemfile_dir` is where the Gemfile
# lives (where bundle install runs); `engine_dir` is where rspec
# runs (where the cache lands). For most projects these match;
# Spree's monorepo splits them (Gemfile at clone-root/spree/, specs
# inside clone-root/spree/core/).
PROJECT_INVOCATIONS = {
  solidus: {
    gemfile_dir: '',
    engine_dir: 'api',
    # Full api engine spec/ tree (~700 examples). Verified clean
    # at the pinned SHA (CI run 25143397673 cell `soak (solidus)`
    # passed in 4m31s with full suite).
    rspec_args: ['spec'],
    # spec/i18n_spec.rb is a hygiene lint asserting the api engine's
    # config/locales/*.yml are i18n-tasks-normalized. The :locale
    # mutation kind appends comment lines to exactly those files, so
    # any locale iter that lands on an api locale file re-selects the
    # spec and fails it - the check working as designed, not a tracer
    # defect. Deterministic nightly casualty: mutation seed 44 always
    # picks api/config/locales/en.yml, so every 50-iter cron died at
    # iter 44. A normalization lint over mutation-target files is
    # structurally incompatible with the append-mutation model.
    rspec_exclude: 'spec/i18n_spec.rb',
    extra_env: { 'DB' => 'sqlite' }
  },
  refinery: {
    gemfile_dir: '',
    engine_dir: '',
    # Refinery's clone-root has no root-level spec/ - specs live
    # per-engine. Pass non-system spec dirs explicitly. system/
    # specs need browser drivers (Capybara + Chrome/Selenium) not
    # configured in CI; lib + controllers + helpers + presenters +
    # models cover ~399 examples cleanly at the pinned main HEAD.
    rspec_args: %w[
      core/spec/lib core/spec/controllers core/spec/helpers core/spec/presenters
      pages/spec/lib pages/spec/controllers pages/spec/helpers pages/spec/presenters pages/spec/models
      images/spec/lib images/spec/models
      resources/spec/lib resources/spec/models
      dragonfly/spec/lib
    ],
    # Refinery v4.1.0 ships two examples sharing one full description
    # (images/spec/models/refinery/image_spec.rb:163 / :207, both
    # "Refinery::Image#thumbnail_dimensions returns correctly with
    # nil"). rspec-tracer's fail_on_duplicates gate (default true)
    # turns that into exit 1 on an otherwise green suite, which
    # failed every nightly iter 1 since the v4.1.0 pin. Duplicate
    # detection + drop stay exercised (the diagnostic still logs and
    # the colliding pair is dropped); only the exit gate is disabled
    # because upstream description hygiene is not the soak's
    # assertion surface.
    extra_env: { 'RSPEC_TRACER_FAIL_ON_DUPLICATES' => 'false' }
  },
  spree: {
    gemfile_dir: 'spree/core',
    engine_dir: 'spree/core',
    # spree/core spec subset minus the SQLite-busy flake on
    # select_shipping_method (4 of 11 examples in that file
    # consistently fail under sqlite due to concurrent transaction
    # locks; flagged in Spree's own pending docs). 1307 examples
    # verified clean locally at the pinned SHA in ~5 min.
    # spec/services explicit dir list with checkout's individual
    # files (minus select_shipping_method) so rspec discovery skips
    # the flake without an --exclude-pattern (which is silently
    # ignored when positional paths are passed - per
    # feedback_rspec_exclude_pattern_positional).
    rspec_args: %w[
      spec/lib spec/finders spec/helpers spec/jobs spec/presenters spec/validators
      spec/services/spree/account
      spec/services/spree/addresses
      spec/services/spree/cart
      spec/services/spree/carts
      spec/services/spree/checkout/add_store_credit_spec.rb
      spec/services/spree/checkout/advance_spec.rb
      spec/services/spree/checkout/get_shipping_rates_spec.rb
      spec/services/spree/checkout/remove_store_credit_spec.rb
      spec/services/spree/checkout/update_spec.rb
      spec/services/spree/classifications
      spec/services/spree/credit_cards
      spec/services/spree/gift_cards
      spec/services/spree/imports
      spec/services/spree/line_items
      spec/services/spree/locales
      spec/services/spree/newsletter
      spec/services/spree/orders
      spec/services/spree/payments
      spec/services/spree/products
      spec/services/spree/sample_data
      spec/services/spree/seeds
      spec/services/spree/shipments
      spec/services/spree/stock_locations
      spec/services/spree/stores
      spec/services/spree/tags
      spec/services/spree/taxons
      spec/services/spree/variants
      spec/services/spree/wallet
    ],
    extra_env: { 'DB' => 'sqlite' }
  }
}.freeze

# 9 mutation kinds rotated deterministically across iters. Same enum
# across projects so iter-N's mutation kind is project-agnostic
# (only the candidate file set differs).
MUTATION_KINDS = %i[model view controller helper factory fixture migration locale gemfile].freeze

# Per-project glob patterns relative to FIXTURE_ROOT (clone root).
# Mutations target the engine_dir set for the project's chosen
# engine; mutating other engines wouldn't trigger any spec re-runs
# under that engine's tracker scope. Empty glob expansions skip the
# iter's mutation rather than crashing.
MUTATION_TARGETS = {
  solidus: {
    model: ['api/app/models/**/*.rb', 'core/app/models/**/*.rb'],
    view: ['api/app/views/**/*.{erb,jbuilder}'],
    controller: ['api/app/controllers/**/*_controller.rb'],
    helper: ['api/app/helpers/**/*_helper.rb'],
    factory: ['api/lib/**/factories/**/*.rb', 'core/lib/**/factories/**/*.rb'],
    fixture: ['api/spec/fixtures/**/*.yml'],
    migration: ['api/db/migrate/*.rb', 'core/db/migrate/*.rb'],
    locale: ['api/config/locales/*.yml', 'core/config/locales/*.yml'],
    gemfile: ['Gemfile']
  },
  refinery: {
    model: ['{core,pages,images,resources}/app/models/refinery/**/*.rb'],
    view: ['{core,pages,images,resources}/app/views/refinery/**/*.{erb,slim,haml}'],
    controller: ['{core,pages,images,resources}/app/controllers/refinery/**/*_controller.rb'],
    helper: ['{core,pages,images,resources}/app/helpers/refinery/**/*_helper.rb'],
    factory: ['{core,pages,images,resources}/spec/factories/**/*.rb'],
    fixture: ['{core,pages,images,resources}/spec/fixtures/**/*.yml'],
    migration: ['{core,pages,images,resources}/db/migrate/*.rb'],
    locale: ['{core,pages,images,resources}/config/locales/*.yml'],
    gemfile: ['Gemfile']
  },
  spree: {
    model: ['spree/core/app/models/spree/**/*.rb'],
    view: ['spree/core/app/views/**/*.{erb,jbuilder}'],
    controller: ['spree/core/app/controllers/spree/**/*_controller.rb'],
    helper: ['spree/core/app/helpers/spree/**/*_helper.rb'],
    factory: ['spree/core/lib/**/factories/**/*.rb'],
    fixture: ['spree/core/spec/fixtures/**/*.yml'],
    migration: ['spree/core/db/migrate/*.rb'],
    locale: ['spree/core/config/locales/*.yml'],
    gemfile: ['spree/Gemfile']
  }
}.freeze

# Per-project default iter counts. Sized to fit the 4 h cron cap
# (workflow `timeout-minutes: 240`) against measured GHA per-iter wall.
# Refinery is small (~70 specs, ~29 s/iter on GHA) so 100 iters fits;
# Solidus's api engine (~700 specs, ~85 s/iter) takes ~70 min at 50.
# Spree's core engine (~1307 specs, ~660 s/iter on GHA EPYC) is the
# bottleneck: at 11 min/iter, a single-cell 50-iter run needs ~9 h
# wall — far past cap. The workflow shards Spree into 2 matrix cells
# (see `.github/workflows/soak.yml`); each cell runs ITERATIONS=20
# (~3.7 h with margin), and the cells use disjoint SHARD_OFFSETs so
# the combined deterministic mutation-seed space across shards covers
# 40 iter-equivalents (4.4 mutation-kind cycles, 30 post-warmup memory
# observations across shards) — most of what the original 50-iter
# design provided.
# Per-iter wall on GHA EPYC is 3-6x M2 Max for Rails-heavy suites; the
# original 1.5-2 h docstring claim assumed M2 Max pacing.
DEFAULT_ITERATIONS = { solidus: 50, refinery: 100, spree: 20 }.freeze

PROJECT = ENV.fetch('SOAK_PROJECT') do
  raise 'SOAK_PROJECT env var required (one of: solidus, refinery, spree)'
end.to_sym
unless MUTATION_TARGETS.key?(PROJECT)
  raise "unknown SOAK_PROJECT: #{PROJECT.inspect} (expected one of: #{MUTATION_TARGETS.keys.join(', ')})"
end

INVOCATION = PROJECT_INVOCATIONS.fetch(PROJECT)
FIXTURE_ROOT = Pathname(
  ENV.fetch('SOAK_FIXTURE_ROOT') { REPO_ROOT.join('tmp/soak-fixtures', PROJECT.to_s).to_s }
).expand_path
GEMFILE_PATH = FIXTURE_ROOT.join(INVOCATION[:gemfile_dir], 'Gemfile')
ENGINE_PATH = FIXTURE_ROOT.join(INVOCATION[:engine_dir])
CACHE_PATH = ENGINE_PATH.join('rspec_tracer_cache')
# GitHub Actions populates `inputs.<name>` with each input's default
# value on `schedule:` triggers (vs `pull_request:` where the inputs
# context is absent), so the soak workflow's `SOAK_ITERATIONS:
# ${{ inputs.iterations }}` resolves to "" on cron runs. ENV.fetch's
# block fallback only fires on UNSET keys, not on set-but-empty ones,
# so a naive `ENV.fetch('SOAK_ITERATIONS') { default }` returned ""
# and `Integer("")` raised. Coerce empty string to "use the
# per-project default" to match the unset semantics.
soak_iterations_env = ENV['SOAK_ITERATIONS'].to_s
soak_iterations_env = nil if soak_iterations_env.empty?
ITERATIONS = Integer(soak_iterations_env || DEFAULT_ITERATIONS.fetch(PROJECT).to_s)
WARMUP_ITERS = Integer(ENV.fetch('SOAK_WARMUP_ITERS', '5'))
MEMORY_BOUND = Float(ENV.fetch('SOAK_MEMORY_BOUND', '1.20'))

# Shard support. When `SOAK_SHARD=N` is set (1-indexed), the mutation
# RNG seed + kind selection use `global_iter = iter + SHARD_OFFSET`
# where `SHARD_OFFSET = (N - 1) * ITERATIONS`. This makes shard 1's
# iter 1..ITERATIONS exercise mutation seeds 1..ITERATIONS, shard 2's
# iter 1..ITERATIONS exercise seeds (ITERATIONS+1)..(2*ITERATIONS), etc.
# Combined across shards, the deterministic mutation-seed space is
# disjoint and covers what a single-cell N*ITERATIONS run would have.
# Empty / unset `SOAK_SHARD` treats as the unsharded default (offset 0)
# so local `task soak:smoke:*` runs and the unsharded Solidus / Refinery
# cells keep their original semantics.
# Used by `.github/workflows/soak.yml`'s Spree matrix split to fit the
# 4 h cron cap while preserving most of the 50-iter signal that a
# single-cell run can no longer get on GHA EPYC.
soak_shard_env = ENV['SOAK_SHARD'].to_s
SHARD = soak_shard_env.empty? ? nil : Integer(soak_shard_env)
SHARD_OFFSET = SHARD.nil? ? 0 : (SHARD - 1) * ITERATIONS
SHARD_LABEL = SHARD.nil? ? '' : " shard #{SHARD}"

# Soak orchestration: subprocess-per-iter pattern needs before(:all)
# fixture-existence sanity + a single multi-statement example. The
# integration-style cops below are tuned for unit specs (small
# examples, single expectation) and don't apply to a multi-iter
# cross-process soak.
# rubocop:disable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/ExampleLength
# rubocop:disable RSpec/NoExpectationExample
RSpec.describe "realworld soak (#{PROJECT}#{SHARD_LABEL})" do
  before(:all) do
    raise "fixture missing: #{FIXTURE_ROOT}\n\nRun `task soak:fixture:#{PROJECT}` first." \
      unless FIXTURE_ROOT.directory?
    raise "fixture Gemfile missing: #{GEMFILE_PATH}" unless GEMFILE_PATH.file?
    raise "fixture engine dir missing: #{ENGINE_PATH}" unless ENGINE_PATH.directory?
    raise "memstat helper missing: #{MEMSTAT_AT_EXIT}" unless MEMSTAT_AT_EXIT.file?
    raise "soak_start helper missing: #{SOAK_START}" unless SOAK_START.file?

    IntegrationCleanup.scrub_default!(ENGINE_PATH)
    FileUtils.rm_rf(SOAK_TMP)
    FileUtils.mkdir_p(SOAK_TMP)
  end

  after(:all) do
    IntegrationCleanup.scrub_default!(ENGINE_PATH)
  end

  it "completes #{ITERATIONS} iterations against #{PROJECT}#{SHARD_LABEL} with no memory leak or crash" do
    skip_if_jruby

    memstats = []
    state = new_soak_state

    begin
      ITERATIONS.times do |i|
        iter = i + 1
        kind, _mutated = mutate_for_iter(iter)
        state[:mutation_kinds][kind] += 1 if kind
        iter_start = Time.now
        announce_iter_start(iter)
        memstat, output, success = run_soak_subprocess(iter)
        state[:iter_timings] << (Time.now - iter_start)
        state[:iter_outcomes] << success
        announce_iter_done(iter, iter_start, success)

        # Pin SHAs are the maintainer-verified trust anchor: at the
        # pinned ref, the full suite runs clean. Any subprocess
        # failure is a real signal (env mismatch, harness break, or
        # actual upstream regression that warrants a pin re-validation).
        unless success
          head = output[0, 2_000]
          tail = output.length > 6_000 ? output[-4_000..] : ''
          chunk = tail.empty? ? head : "#{head}\n[... truncated ...]\n#{tail}"
          state[:failure] = { iter: iter, reason: 'subprocess', detail: chunk }
          raise "iter #{iter}#{SHARD_LABEL} (#{PROJECT}) subprocess failed:\n#{chunk}"
        end

        if memstat.nil?
          state[:failure] = { iter: iter, reason: 'no_memstat', detail: nil }
          raise "iter #{iter}#{SHARD_LABEL} (#{PROJECT}): no memstat captured"
        end

        memstats << memstat
        verify_cache_state(iter)
        state[:cache_passes] += 1
      end

      enforce_memory_bound(memstats)
    rescue StandardError => e
      # Capture memory-bound violations (and any other late-stage
      # failures) for the summary writer; re-raise to preserve the
      # assertion semantics.
      state[:failure] ||= { iter: nil, reason: e.class.name, detail: e.message }
      raise
    ensure
      write_soak_summary(state, memstats)
    end
  end
  # rubocop:enable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/ExampleLength
  # rubocop:enable RSpec/NoExpectationExample

  # -- helpers ---------------------------------------------------

  def skip_if_jruby
    skip 'soak runs MRI-only (JRuby x Rails subprocess floor too high)' if RUBY_ENGINE != 'ruby'
  end

  def mutate_for_iter(iter)
    # Apply SHARD_OFFSET so each shard exercises a disjoint slice of
    # the deterministic mutation-seed space. global_iter is what feeds
    # the RNG seed + kind selection; the original `iter` 1..ITERATIONS
    # is still used for filesystem paths (iter_dir) and announce
    # markers so per-shard cell output is human-readable.
    # Returns [kind, mutated?] so the caller's summary state can
    # record which mutation kinds got exercised (mutated? = false when
    # the kind had no glob candidates for this project).
    global_iter = iter + SHARD_OFFSET
    rng = Random.new(global_iter)
    kind = MUTATION_KINDS[(global_iter - 1) % MUTATION_KINDS.size]
    candidates = mutation_candidates(kind)
    if candidates.empty?
      # Some projects don't populate every mutation kind. Skip the
      # iter's mutation rather than crashing - the iter still runs
      # and exercises the tracker via prior mutations' accumulated
      # invalidation surface.
      msg = "iter #{iter}#{SHARD_LABEL} (#{PROJECT}): no mutation candidates for kind #{kind.inspect}"
      puts "#{msg} - skipping mutation" # rubocop:disable RSpec/Output
      return [kind, false]
    end

    target = candidates[rng.rand(candidates.size)]
    suffix = mutation_suffix(target, iter, kind)
    File.open(target, 'a') { |f| f.write(suffix) }
    [kind, true]
  end

  def mutation_candidates(kind)
    patterns = MUTATION_TARGETS.fetch(PROJECT).fetch(kind, [])
    patterns
      .flat_map { |p| Dir.glob(FIXTURE_ROOT.join(p).to_s) }
      .reject { |f| ignore_path?(f) }
      .uniq
  end

  # Skip baseline files we don't want to mutate - boilerplate
  # ApplicationRecord / ApplicationController etc. that every spec
  # depends on. Mutating them rebuilds the entire suite cache, which
  # is a valid stress but skews the per-iter signal toward
  # whole-suite-invalidator rebuilds. Gemfile is the dedicated
  # whole-suite-invalidator kind; baseline Ruby files are noise.
  def ignore_path?(path)
    base = File.basename(path)
    %w[application_record.rb application_controller.rb application_helper.rb
       application_mailer.rb application_job.rb].include?(base)
  end

  # Comment syntax per file extension. Append-style mutations are
  # idempotent across iters: each iter adds ONE comment line; the
  # file remains semantically equivalent (Rails / RSpec / Bundler /
  # FactoryBot / YAML all tolerate trailing comments). The tracker
  # observes the change via mtime / size / digest invalidation -
  # which is what the soak is testing.
  def mutation_suffix(path, iter, _kind)
    label = "soak iter #{iter}#{SHARD_LABEL} (#{PROJECT})"
    case File.extname(path)
    when '.erb'  then "\n<%# #{label} %>\n"
    when '.slim' then "\n/ #{label}\n"
    when '.haml' then "\n-# #{label}\n"
    else              "\n# #{label}\n"
    end
  end

  # rubocop:disable RSpec/Output -- iter-progress markers are the spec's
  #   primary observability artifact; without them the GHA UI shows zero
  #   activity for 30+ min which looks like a hang.
  def announce_iter_start(iter)
    $stdout.write("\n=== #{PROJECT}#{SHARD_LABEL} iter #{iter}/#{ITERATIONS} starting ===\n")
    $stdout.flush
  end

  def announce_iter_done(iter, started_at, success)
    elapsed = format('%.1f', Time.now - started_at)
    state = success ? 'OK' : 'FAIL'
    header = "=== #{PROJECT}#{SHARD_LABEL} iter #{iter}/#{ITERATIONS}"
    $stdout.write("#{header} done in #{elapsed}s (status=#{state}) ===\n\n")
    $stdout.flush
  end
  # rubocop:enable RSpec/Output

  def soak_subprocess_env(iter_dir)
    {
      'BUNDLE_GEMFILE' => GEMFILE_PATH.to_s,
      'RUBYOPT' => "-r#{SOAK_START} -r#{MEMSTAT_AT_EXIT}",
      'SOAK_MEMSTAT_DIR' => iter_dir.to_s,
      'RSPEC_TRACER' => '1',
      # Delete CI from the child env (nil unsets it in Open3's env
      # hash). Empty string is TRUTHY in Ruby, which trips Gemfile
      # conditionals like Spree's `gem 'mysql2' if ENV['CI']` and
      # makes Bundler.setup demand a non-resolved gem.
      'CI' => nil,
      'RAILS_ENV' => 'test'
    }.merge(INVOCATION[:extra_env])
  end

  def run_soak_subprocess(iter)
    iter_dir = SOAK_TMP.join("iter-#{iter}")
    FileUtils.mkdir_p(iter_dir)
    env = soak_subprocess_env(iter_dir)

    # Stream subprocess output line-by-line to $stdout in real time
    # (vs Open3.capture2e's buffer-until-exit) so the soak appears
    # LIVE in CI logs / local terminal. Each line is also
    # accumulated to output_buffer for the failure-case raise.
    output_buffer = +''
    status = nil
    # --exclude-pattern is honored here because rspec_args passes
    # DIRECTORIES (rspec filters files gathered from dir globbing);
    # explicit positional file paths would silently bypass it.
    exclude_args =
      INVOCATION[:rspec_exclude] ? ['--exclude-pattern', INVOCATION[:rspec_exclude]] : []
    Bundler.with_unbundled_env do
      Open3.popen2e(env, 'bundle', 'exec', 'rspec',
                    '--no-color', '--format', 'progress',
                    *exclude_args,
                    *INVOCATION[:rspec_args],
                    chdir: ENGINE_PATH.to_s) do |_stdin, out, wait_thr|
        out.each_line do |line|
          $stdout.write("  [#{PROJECT} iter #{iter}] #{line}") # rubocop:disable RSpec/Output
          $stdout.flush
          output_buffer << line
        end
        status = wait_thr.value
      end
    end

    [collect_memstat(iter_dir), output_buffer, status.success?]
  end

  def collect_memstat(iter_dir)
    files = Dir.glob(iter_dir.join('memstat-*.json').to_s)
    return nil if files.empty?

    snapshots = files.filter_map do |f|
      JSON.parse(File.read(f))
    rescue StandardError
      nil
    end
    snapshots.max_by { |s| s.fetch('total_memsize', 0) }
  end

  def verify_cache_state(iter)
    raise "iter #{iter}#{SHARD_LABEL} (#{PROJECT}): rspec_tracer_cache/ missing at #{CACHE_PATH}" \
      unless CACHE_PATH.directory?

    last_run = CACHE_PATH.join('last_run.json')
    raise "iter #{iter}#{SHARD_LABEL} (#{PROJECT}): last_run.json missing" unless last_run.file?

    manifest = JSON.parse(last_run.read)
    raise "iter #{iter}#{SHARD_LABEL} (#{PROJECT}): run_id missing" if manifest['run_id'].to_s.empty?
  end

  def enforce_memory_bound(memstats)
    raise 'no memstats captured' if memstats.empty?

    if memstats.length < WARMUP_ITERS
      # Smoke runs (typically 10 iters) and ad-hoc runs with
      # SOAK_ITERATIONS < WARMUP_ITERS skip the bound assertion -
      # there's no warm-up baseline to compare against. The full
      # 50/100-iter cron always exceeds WARMUP_ITERS so the gate
      # fires there. Print summary as the diagnostic artifact.
      puts "Memory bound skipped (#{memstats.length} iters < WARMUP_ITERS=#{WARMUP_ITERS})" # rubocop:disable RSpec/Output
      return
    end

    baseline = memstats[WARMUP_ITERS - 1].fetch('total_memsize')
    bound = baseline * MEMORY_BOUND

    growths = []
    memstats.drop(WARMUP_ITERS).each_with_index do |stat, idx|
      iter = WARMUP_ITERS + idx + 1
      memsize = stat.fetch('total_memsize')
      ratio = memsize.to_f / baseline
      growths << [iter, memsize, ratio]
    end

    summary = growths.map { |iter, _, ratio| "iter #{iter}: #{format('%.4f', ratio)}x" }
      .join("\n  ")
    # The growth-ratio summary is a CI / nightly-cron diagnostic;
    # post-merge dashboards plot it as the soak SLI signal. RSpec/Output
    # disabled deliberately - this puts is the spec's primary
    # observability artifact.
    puts "Memory growth (#{PROJECT}#{SHARD_LABEL} baseline iter #{WARMUP_ITERS} = #{baseline} bytes):\n  #{summary}" # rubocop:disable RSpec/Output

    violations = growths.select { |_, memsize, _| memsize > bound }
    return if violations.empty?

    raise "memory bound exceeded for #{PROJECT}#{SHARD_LABEL} (baseline #{baseline}, bound #{bound}):\n" +
      violations.map { |iter, memsize, ratio|
        "  iter #{iter}: #{memsize} bytes (#{format('%.4f', ratio)}x)"
      }.join("\n")
  end

  # -- summary --------------------------------------------------
  #
  # write_soak_summary renders tmp/soak/summary.md +
  # tmp/soak/summary.json at the end of every soak run (success or
  # fail) so a human can see the SLI signal at the run page without
  # downloading the memstats artifact:
  #
  #   - pass/fail + reason
  #   - per-iter wall pacing (mean/p50/p95/min/max/total)
  #   - memory baseline + max growth ratio + bound violations
  #   - mutation-kind frequency (did the 9-kind rotation actually fire
  #     every kind it intended to?)
  #   - cache-state pass count
  #   - failure context (iter + reason + tail of failing subprocess output)
  #
  # The workflow's "Render soak summary" step pipes summary.md into
  # $GITHUB_STEP_SUMMARY so it renders on the GHA run page. summary.json
  # rides along in the memstats artifact for machine consumption / future
  # trend dashboarding.
  #
  # Failures in the summary writer itself are warned + swallowed so they
  # don't mask the soak's primary assertion result.

  def new_soak_state
    {
      iter_timings: [],
      iter_outcomes: [],
      mutation_kinds: Hash.new(0),
      cache_passes: 0,
      failure: nil
    }
  end

  def write_soak_summary(state, memstats)
    FileUtils.mkdir_p(SOAK_TMP) unless SOAK_TMP.directory?

    pacing = compute_pacing_stats(state[:iter_timings])
    memory = compute_memory_stats(memstats)

    md = render_summary_markdown(state, pacing, memory)
    json = build_summary_json(state, pacing, memory)

    File.write(SOAK_TMP.join('summary.md'), md)
    File.write(SOAK_TMP.join('summary.json'), JSON.pretty_generate(json))

    # Stdout copy for log scannability (same content as summary.md).
    $stdout.write("\n#{md}\n") # rubocop:disable RSpec/Output
    $stdout.flush
  rescue StandardError => e
    warn "soak summary write failed: #{e.class}: #{e.message}"
  end

  def compute_pacing_stats(timings)
    return nil if timings.empty?

    sorted = timings.sort
    {
      count: timings.size,
      mean: timings.sum.to_f / timings.size,
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      min: sorted.first,
      max: sorted.last,
      total: timings.sum
    }
  end

  def compute_memory_stats(memstats)
    return nil if memstats.length < WARMUP_ITERS

    baseline = memstats[WARMUP_ITERS - 1].fetch('total_memsize')
    bound = baseline * MEMORY_BOUND
    growths = compute_memory_growths(memstats, baseline)
    max_entry = growths.max_by { |_, _, ratio| ratio } || [nil, baseline, 1.0]
    violations = growths.select { |_, memsize, _| memsize > bound }

    {
      baseline_bytes: baseline,
      bound_bytes: bound.to_i,
      bound_multiplier: MEMORY_BOUND,
      max_growth_iter: max_entry[0],
      max_growth_bytes: max_entry[1],
      max_growth_ratio: max_entry[2],
      violations: violations.map { |iter, memsize, ratio| { iter: iter, bytes: memsize, ratio: ratio } }
    }
  end

  def compute_memory_growths(memstats, baseline)
    memstats.drop(WARMUP_ITERS).each_with_index.map do |stat, idx|
      iter = WARMUP_ITERS + idx + 1
      memsize = stat.fetch('total_memsize')
      [iter, memsize, memsize.to_f / baseline]
    end
  end

  def render_summary_markdown(state, pacing, memory)
    md = "## soak summary: #{PROJECT}#{SHARD_LABEL}\n\n"
    md << render_result_line(state)
    md << render_iters_line(state)
    md << render_pacing_line(pacing) if pacing
    md << render_memory_lines(memory) if memory
    md << render_mutation_line(state[:mutation_kinds]) if state[:mutation_kinds].any?
    md << render_cache_line(state)
    md << render_failure_context(state[:failure]) if state[:failure]
    md
  end

  def render_result_line(state)
    fail_count = state[:iter_outcomes].count(false)
    attempted = state[:iter_outcomes].size
    if state[:failure]
      iter_label = state[:failure][:iter] ? "iter #{state[:failure][:iter]}" : 'pre-iter'
      "**Result:** ❌ fail (#{iter_label}, reason: #{state[:failure][:reason]})\n\n"
    elsif fail_count.positive?
      "**Result:** ⚠️ partial (#{fail_count}/#{attempted} iters failed)\n\n"
    elsif attempted < ITERATIONS
      "**Result:** ⚠️ incomplete (#{attempted}/#{ITERATIONS} iters ran)\n\n"
    else
      "**Result:** ✅ pass\n\n"
    end
  end

  def render_iters_line(state)
    ok = state[:iter_outcomes].count(true)
    fail = state[:iter_outcomes].count(false)
    "**Iters:** #{ok} OK · #{fail} FAIL · #{ITERATIONS} planned\n\n"
  end

  def render_pacing_line(pacing)
    f = ->(t) { format('%.1f', t) }
    "**Per-iter wall:** mean #{f[pacing[:mean]]}s · p50 #{f[pacing[:p50]]}s · " \
      "p95 #{f[pacing[:p95]]}s · min #{f[pacing[:min]]}s · max #{f[pacing[:max]]}s · " \
      "total #{format('%.1f', pacing[:total] / 60)} min\n\n"
  end

  def render_memory_lines(memory)
    mult = format('%.2f', memory[:bound_multiplier])
    ratio = format('%.4f', memory[:max_growth_ratio])
    out = "**Memory:** baseline (iter #{WARMUP_ITERS}) #{format_bytes(memory[:baseline_bytes])} · " \
          "bound #{format_bytes(memory[:bound_bytes])} (#{mult}×) · " \
          "max growth #{ratio}× (iter #{memory[:max_growth_iter] || '?'})\n\n"
    return out if memory[:violations].empty?

    out << "**Memory violations:**\n"
    memory[:violations].each do |v|
      out << "  - iter #{v[:iter]}: #{format_bytes(v[:bytes])} (#{format('%.4f', v[:ratio])}×)\n"
    end
    out << "\n"
    out
  end

  def render_mutation_line(kinds)
    ordered = MUTATION_KINDS.filter_map { |k| [k, kinds[k]] if kinds.key?(k) }
    "**Mutation kinds:** #{ordered.map { |k, n| "#{k}=#{n}" }.join(' · ')}\n\n"
  end

  def render_cache_line(state)
    attempted = state[:iter_outcomes].size
    "**Cache state checks:** #{state[:cache_passes]}/#{attempted} passed\n\n"
  end

  def render_failure_context(failure)
    out = +"### Failure context\n\n"
    out << "**Iter:** #{failure[:iter] || 'pre-iter'}  \n"
    out << "**Reason:** #{failure[:reason]}\n\n"
    return out unless failure[:detail]

    detail = failure[:detail].to_s
    excerpt = detail.length > 1500 ? "[... truncated to last 1500 bytes ...]\n#{detail[-1500..]}" : detail
    out << "```\n#{excerpt}\n```\n"
    out
  end

  def build_summary_json(state, pacing, memory)
    {
      project: PROJECT,
      shard: SHARD,
      iterations_planned: ITERATIONS,
      iterations_attempted: state[:iter_outcomes].size,
      iterations_ok: state[:iter_outcomes].count(true),
      iterations_fail: state[:iter_outcomes].count(false),
      pacing: pacing,
      memory: memory,
      mutation_kinds: state[:mutation_kinds],
      cache_state_passes: state[:cache_passes],
      failure: state[:failure] && { iter: state[:failure][:iter], reason: state[:failure][:reason] }
    }
  end

  def percentile(sorted, pct)
    return nil if sorted.empty?
    return sorted.first if sorted.size == 1

    rank = (sorted.size - 1) * pct
    lower = sorted[rank.floor]
    upper = sorted[rank.ceil]
    lower + ((upper - lower) * (rank - rank.floor))
  end

  def format_bytes(bytes)
    return '?' unless bytes

    units = %w[B KiB MiB GiB TiB]
    size = bytes.to_f
    unit = 0
    while size >= 1024 && unit < units.size - 1
      size /= 1024
      unit += 1
    end
    "#{format('%.1f', size)} #{units[unit]}"
  end
end
