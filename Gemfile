# frozen_string_literal: true

source 'https://rubygems.org'

group :development do
  gem 'pry', '~> 0.14'
  gem 'rake', '~> 13.2'
  gem 'rantly', '~> 2.0'

  # Dev-only tool gems are pinned EXACTLY (not `~>`) so a fresh CI
  # resolve cannot drift while main is dormant: new tool releases
  # (new cops, parser changes, mutation-set changes) arrive via
  # deliberate Dependabot bump PRs instead of breaking lint/mutation
  # on untouched code. Runtime/matrix-driven gems below stay loose on
  # purpose - their resolution spread IS the compatibility matrix.
  gem 'rubocop', '1.90.0'
  gem 'rubocop-performance', '1.26.1'
  gem 'rubocop-rake', '0.7.1'
  gem 'rubocop-rspec', '3.10.2'

  gem 'simplecov', '~> 0.22'
  gem 'sprockets', '~> 4.2'
  gem 'uglifier', '~> 4.2'
  gem 'yard', '~> 0.9'
  gem 'yui-compressor', '~> 0.12'

  # Optional / matrix-driven runtime deps. Each is a `>= floor` so the
  # default (per-PR / per-main) Bundler resolve picks the latest
  # installable on the cell's Ruby - matching what an end user gets
  # with `gem '<name>'` and no further pin in their own Gemfile. The
  # weekly `combinations` workflow overrides each axis explicitly via
  # the named ENV var to exercise the full supported cross-product.
  #
  # Env names are prefixed `RSPEC_TRACER_*` to keep them in their own
  # namespace. `SQLITE3_VERSION` and `PARALLEL_TESTS_VERSION` (without
  # the prefix) are set by `full-matrix.yml` at STEP level for the Rails
  # / parallel-tests fixture Gemfiles - sharing those names between the
  # outer Gemfile and the fixture Gemfile would cause the outer to
  # silently re-resolve at `bundle exec` time to a version not present
  # in the install-time bundle. Prefixing keeps the two scopes
  # independent. `RSPEC_VERSION` is intentionally NOT prefixed: the
  # workflow always sets it at JOB level (so setup-ruby's bundle install
  # and the test step's bundle exec see the same value), and the prior
  # cucumber-era fixture Gemfiles (retired in 2.0.0) also read the
  # unprefixed name - keeping the existing name avoids churn for users
  # tracking the env in their own Gemfiles.
  #
  # Floors are the lowest currently-maintained major-line of each gem.
  # See .github/workflows/combinations.yml for the explicit matrix.

  # rspec: 3.12 (LTS-ish) and 3.13 (current). Default resolves to 3.13.
  gem 'rspec', ENV.fetch('RSPEC_VERSION', '>= 3.12')

  # Ruby 4.0 extracted `benchmark` from the stdlib into a bundled gem.
  # benchmark/harness.rb uses Benchmark.realtime + spec/benchmark/
  # harness_spec.rb requires the harness, both of which need the gem
  # in the bundle on 4.0+. On Ruby <= 3.4 it's still in stdlib so
  # `gem 'benchmark'` is harmless. Floor of 0.4 is the first 4.0-
  # extracted release.
  gem 'benchmark', ENV.fetch('RSPEC_TRACER_BENCHMARK_VERSION', '>= 0.4')

  # parallel + parallel_tests: 1.x / 2.x and 4.x / 5.x respectively.
  # parallel 2.x requires Ruby >= 3.3; on lower Rubies Bundler picks 1.x.
  gem 'parallel', ENV.fetch('RSPEC_TRACER_PARALLEL_VERSION', '>= 1.26')
  gem 'parallel_tests', ENV.fetch('RSPEC_TRACER_PARALLEL_TESTS_VERSION', '>= 4.10')

  # redis: 4.x (last patched 4.8.1) and 5.x (current 5.4.x). Both lines
  # install on every Ruby in the matrix. Default resolves to 5.x.
  gem 'redis', ENV.fetch('RSPEC_TRACER_REDIS_VERSION', '>= 4.8')

  # connection_pool: 2.x (universal) and 3.x (Ruby >= 3.2 only). On
  # Ruby 3.1 / JRuby 9.4 Bundler backtracks to 2.x; on 3.2+ it picks 3.x.
  gem 'connection_pool', ENV.fetch('RSPEC_TRACER_CONNECTION_POOL_VERSION', '>= 2.5')

  # msgpack: single 1.x major line. -java platform variant exists for
  # JRuby. Both 1.7.x and 1.8.x install on every Ruby in the matrix.
  gem 'msgpack', ENV.fetch('RSPEC_TRACER_MSGPACK_VERSION', '>= 1.7')

  # erb: pulled transitively via irb -> rdoc -> erb. erb 5.0+ bumped its
  # required_ruby_version to 3.2+; the matrix supports Ruby 3.1, so
  # Bundler resolution (and Dependabot, which pretends to resolve under
  # the lowest matrix Ruby) fails when erb >= 5.0 wins. Pin to the 4.x
  # line so resolution succeeds on every supported Ruby. Drop this pin
  # if the Ruby 3.1 floor is ever dropped from the matrix.
  gem 'erb', ENV.fetch('RSPEC_TRACER_ERB_VERSION', '~> 4.0')

  # sqlite3: per-Ruby gate because precompiled-binary ceilings differ
  # between 1.x and 2.x lines and the source-build path needs a C
  # compiler. The default branches keep CI-cache hits maximal:
  #   - Ruby 3.1: only sqlite3 1.x precompiled fits the ceiling.
  #   - Ruby 3.2 / 3.3: both 1.x and 2.x precompiled work; default 2.x.
  #   - Ruby 3.4 / 4.0: 1.x precompiled is out of ceiling (`< 3.4.dev`);
  #     default 2.x. The combinations matrix can still override to
  #     '~> 1.7' to force a source-build path on those Rubies.
  # JRuby has no installable sqlite3 (no -java variant); gated at PARSE
  # time so Bundler does not even attempt to resolve the gem.
  # SqliteBackend uses only stable sqlite3 API (Database.new / execute
  # / get_first_row / transaction(:immediate)) identical across 1.x
  # and 2.x; either pin satisfies the backend's runtime needs.
  if RUBY_ENGINE == 'ruby'
    if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.2')
      gem 'sqlite3', ENV.fetch('RSPEC_TRACER_SQLITE3_VERSION', '>= 2.0')
    else
      gem 'sqlite3', ENV.fetch('RSPEC_TRACER_SQLITE3_VERSION', '~> 1.7')
    end
  end

  # Mutation testing — MRI >= 3.3 only. mutant 0.16's own README says
  # "3.2+", but its transitive dep `unparser 0.9.0` declares
  # `required_ruby_version >= 3.3`, so resolve fails on Ruby 3.2
  # despite mutant's claim. Also doesn't target JRuby. Use a parse-time
  # `if` (not `install_if`) so the gem is not declared at all on
  # incompatible cells; `install_if` only gates install time and
  # Bundler would still refuse to resolve the dep graph when the lock
  # is not committed. Pinned exactly (like the rubocop gems above) so
  # a new mutant release cannot change the mutation set / kill gate on
  # untouched code; Dependabot bumps it deliberately.
  gem 'mutant-rspec', '0.16.3' if RUBY_ENGINE == 'ruby' && Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3')

  # Hot-path profiling — MRI only (stackprof relies on rb_postponed_job_*
  # APIs that JRuby + TruffleRuby don't implement). Used by `task
  # profile:*` to identify allocation / wall-clock hot spots in the
  # tracker pipeline. Microbenchmark scenarios under benchmark/scenarios/
  # are wrapped via benchmark/profile.rb's StackProf.run driver; the
  # gem is only required there, never by lib/ code.
  gem 'stackprof', '~> 0.2' if RUBY_ENGINE == 'ruby'

  # Coexistence smoke specs. Used only by
  # spec/regressions/*_coexistence_spec.rb to verify that popular
  # RSpec extensions compose with rspec-tracer's Module#prepend chain
  # on RSpec::Core::Runner / Reporter. Installed by default but never
  # required by lib/ or unit specs - the regression specs explicitly
  # require them in subprocess shape, so the outer rspec process is
  # unaffected. knapsack (free, local-only test-splitter) rounds
  # out the retry+rerun coverage; knapsack_pro shares
  # the same RSpec hook surface but requires an API key and a
  # network-bound service, so the smoke uses `knapsack` as the
  # composition fingerprint.
  gem 'knapsack', '~> 4.0'
  gem 'rspec-rerun', '~> 1.1'
  gem 'rspec-retry', '~> 0.6'
end

gemspec
