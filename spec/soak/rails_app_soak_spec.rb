# frozen_string_literal: true

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'pathname'

# Nightly soak test against spec/fixtures/rails_app_big/ (4x clone of
# spec/fixtures/rails_app/ produced by scripts/build_rails_app_big.rb;
# ~1208 examples). 100 subprocess iterations, deterministic-seeded
# random file mutation per iter (rotation through 9 kinds), assert
# memstat[N].total_memsize <= memstat[5].total_memsize * 1.05 for
# N >= 6 (iter 5 = post-warm-up baseline; lazy-loads settled).
#
# Excluded from the default rspec sweep via .rspec --exclude-pattern.
# Run via:
#   task soak:smoke   # 10 iters, ~5 min   - pre-PR parity proxy
#   task soak:full    # 100 iters, ~3-4 h  - nightly cron
#
# Iteration mechanism: subprocess per iter via Open3.capture2e (M5.1
# cold-subprocess test-isolation contract preserved per
# feedback_jruby_ci_subprocess_floor); NO fork() in the spec - if
# ever introduced, the child must Process.exit!(0) per
# feedback_simplecov_fork_poisoning.
#
# Cache state assertions only; no coverage.json byte-equivalence
# (M8.0 domain - would require CI= empty pinning per
# feedback_rails_eager_load_coverage_timing). Cleanup-guard hygiene
# via spec/support/integration_cleanup.rb (M8.2).

REPO_ROOT = Pathname(__dir__).parent.parent.expand_path
FIXTURE_ROOT = REPO_ROOT.join('spec/fixtures/rails_app_big')
SOAK_TMP = REPO_ROOT.join('tmp/soak')
MEMSTAT_AT_EXIT = REPO_ROOT.join('spec/soak/memstat_at_exit.rb')

require REPO_ROOT.join('spec/support/integration_cleanup').to_s

# 9 mutation kinds per the brief. Gemfile (not Gemfile.lock) is the
# whole-suite-invalidator class because Gemfile.lock has Bundler-
# specific format that doesn't tolerate trailing comments cleanly;
# Gemfile is the equivalent watched dep file with Ruby comment
# syntax. Same WholeSuiteInvalidator effect on the tracker side.
MUTATION_KINDS = %i[model view controller helper factory fixture migration locale gemfile].freeze

ITERATIONS = Integer(ENV.fetch('SOAK_ITERATIONS', '100'))
WARMUP_ITERS = Integer(ENV.fetch('SOAK_WARMUP_ITERS', '5'))
MEMORY_BOUND = Float(ENV.fetch('SOAK_MEMORY_BOUND', '1.05'))

RSpec.describe 'rails_app_big soak' do
  before(:all) do
    raise "fixture missing: #{FIXTURE_ROOT}" unless FIXTURE_ROOT.directory?
    raise "memstat helper missing: #{MEMSTAT_AT_EXIT}" unless MEMSTAT_AT_EXIT.file?

    IntegrationCleanup.scrub_default!(FIXTURE_ROOT)
    FileUtils.rm_rf(SOAK_TMP)
    FileUtils.mkdir_p(SOAK_TMP)

    ensure_fixture_bundled
    ensure_db_prepared
  end

  after(:all) do
    IntegrationCleanup.scrub_default!(FIXTURE_ROOT)
  end

  it "completes #{ITERATIONS} iterations with no memory leak or crash" do
    skip_if_jruby

    memstats = []

    ITERATIONS.times do |i|
      iter = i + 1
      mutate_for_iter(iter)
      memstat, output, success = run_soak_subprocess(iter)

      unless success
        tail = output[-2_000..] || output
        raise "iter #{iter} subprocess failed:\n#{tail}"
      end

      raise "iter #{iter}: no memstat captured" if memstat.nil?

      memstats << memstat
      verify_cache_state(iter)
    end

    enforce_memory_bound(memstats)
  end

  # -- helpers ---------------------------------------------------

  def skip_if_jruby
    skip 'soak runs MRI-only (JRuby x Rails subprocess floor too high)' if RUBY_ENGINE != 'ruby'
  end

  # Bundle install + db:test:prepare for the fixture. Uses
  # Bundler.with_unbundled_env to clear the outer rspec-tracer
  # Bundler context (RUBYOPT=-rbundler/setup, BUNDLE_GEMFILE,
  # BUNDLE_PATH, etc. all leak from `bundle exec rspec` into child
  # processes) before invoking the fixture's bundle. Same pattern as
  # spec/support/fixture_bundle_helper.rb (M8.6-B). Cross-interpreter
  # safety: if `bundle check` fails, wipe Gemfile.lock and re-resolve
  # per feedback_cross_interpreter_fixture_helper.
  def ensure_fixture_bundled
    Bundler.with_unbundled_env do
      Dir.chdir(FIXTURE_ROOT) do
        gemfile_env = { 'BUNDLE_GEMFILE' => FIXTURE_ROOT.join('Gemfile').to_s }
        unless system(gemfile_env, 'bundle', 'check', out: File::NULL, err: File::NULL)
          FileUtils.rm_f(FIXTURE_ROOT.join('Gemfile.lock'))
          system(gemfile_env, 'bundle', 'install', '--quiet') ||
            raise('soak: bundle install failed in rails_app_big')
        end
      end
    end
  end

  def ensure_db_prepared
    Bundler.with_unbundled_env do
      Dir.chdir(FIXTURE_ROOT) do
        gemfile_env = { 'BUNDLE_GEMFILE' => FIXTURE_ROOT.join('Gemfile').to_s }
        system(gemfile_env, 'bundle', 'exec', 'rails', 'db:test:prepare',
               out: File::NULL, err: File::NULL) ||
          raise('soak: rails db:test:prepare failed in rails_app_big')
      end
    end
  end

  def mutate_for_iter(iter)
    rng = Random.new(iter)
    kind = MUTATION_KINDS[(iter - 1) % MUTATION_KINDS.size]
    candidates = mutation_candidates(kind)
    raise "no mutation candidates for kind #{kind.inspect}" if candidates.empty?

    target = candidates[rng.rand(candidates.size)]
    suffix = mutation_suffix(target, iter, kind)
    File.open(target, 'a') { |f| f.write(suffix) }
  end

  def mutation_candidates(kind)
    case kind
    when :model
      Dir.glob(FIXTURE_ROOT.join('app/models/*.rb'))
         .reject { |f| File.basename(f) == 'application_record.rb' }
    when :view
      Dir.glob(FIXTURE_ROOT.join('app/views/**/*.{erb,slim,jbuilder}'))
    when :controller
      Dir.glob(FIXTURE_ROOT.join('app/controllers/*_controller.rb'))
         .reject { |f| File.basename(f) == 'application_controller.rb' }
    when :helper
      Dir.glob(FIXTURE_ROOT.join('app/helpers/*_helper.rb'))
         .reject { |f| File.basename(f) == 'application_helper.rb' }
    when :factory
      Dir.glob(FIXTURE_ROOT.join('spec/factories/*.rb'))
    when :fixture
      Dir.glob(FIXTURE_ROOT.join('spec/fixtures/*.yml'))
    when :migration
      Dir.glob(FIXTURE_ROOT.join('db/migrate/*.rb'))
    when :locale
      Dir.glob(FIXTURE_ROOT.join('config/locales/*.yml'))
    when :gemfile
      [FIXTURE_ROOT.join('Gemfile').to_s]
    else
      []
    end
  end

  # Comment syntax per file extension. Append-style mutations are
  # idempotent across iters: each iter adds ONE comment line; the
  # file remains semantically equivalent (Rails / RSpec / Bundler /
  # FactoryBot / YAML all tolerate trailing comments). The tracker
  # observes the change via mtime / size / digest invalidation -
  # which is what the soak is testing.
  def mutation_suffix(path, iter, kind)
    label = "soak iter #{iter} (#{kind})"
    case File.extname(path)
    when '.erb'      then "\n<%# #{label} %>\n"
    when '.slim'     then "\n/ #{label}\n"
    when '.jbuilder' then "\n# #{label}\n"
    when '.yml'      then "\n# #{label}\n"
    else                  "\n# #{label}\n"
    end
  end

  def run_soak_subprocess(iter)
    iter_dir = SOAK_TMP.join("iter-#{iter}")
    FileUtils.mkdir_p(iter_dir)

    env = {
      'BUNDLE_GEMFILE' => FIXTURE_ROOT.join('Gemfile').to_s,
      'RUBYOPT' => "-r#{MEMSTAT_AT_EXIT}",
      'SOAK_MEMSTAT_DIR' => iter_dir.to_s,
      'RSPEC_TRACER' => '1',
      # Don't poison the tracker with the outer rspec's CI flag - the
      # rails_helper.rb's eager_load reads ENV['CI'] and shifts the
      # Coverage timing per feedback_rails_eager_load_coverage_timing.
      'CI' => '',
      'RAILS_ENV' => 'test'
    }

    Bundler.with_unbundled_env do
      output, status = Open3.capture2e(env, 'bundle', 'exec', 'rspec',
                                       '--no-color', '--format', 'progress',
                                       chdir: FIXTURE_ROOT.to_s)
      [collect_memstat(iter_dir), output, status.success?]
    end
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
    cache_dir = FIXTURE_ROOT.join('rspec_tracer_cache')
    raise "iter #{iter}: rspec_tracer_cache/ missing" unless cache_dir.directory?

    last_run = cache_dir.join('last_run.json')
    raise "iter #{iter}: last_run.json missing" unless last_run.file?

    manifest = JSON.parse(last_run.read)
    raise "iter #{iter}: run_id missing" if manifest['run_id'].to_s.empty?
  end

  def enforce_memory_bound(memstats)
    raise 'no memstats captured' if memstats.length < WARMUP_ITERS

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
    puts "Memory growth (baseline iter #{WARMUP_ITERS} = #{baseline} bytes):\n  #{summary}"

    violations = growths.select { |_, memsize, _| memsize > bound }
    return if violations.empty?

    raise "memory bound exceeded (baseline #{baseline}, bound #{bound}):\n" +
          violations.map { |iter, memsize, ratio|
            "  iter #{iter}: #{memsize} bytes (#{format('%.4f', ratio)}x)"
          }.join("\n")
  end
end
