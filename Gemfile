# frozen_string_literal: true

source 'https://rubygems.org'

group :development do
  gem 'aruba', '~> 2.2'
  gem 'cucumber', '~> 9.2'
  gem 'pry', '~> 0.14'
  gem 'rake', '~> 13.2'
  gem 'rantly', '~> 2.0'
  gem 'rubocop', '~> 1.60'
  gem 'rubocop-performance', '~> 1.20'
  gem 'rubocop-rake', '~> 0.6'
  gem 'rubocop-rspec', '~> 3.0'
  gem 'simplecov', '~> 0.22'
  gem 'sprockets', '~> 4.2'
  gem 'uglifier', '~> 4.2'
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
  # and the test step's bundle exec see the same value), and several
  # cucumber sample_projects/Gemfiles also read it - keeping the
  # existing name avoids fanning out the rename.
  #
  # Floors are the lowest currently-maintained major-line of each gem.
  # See .github/workflows/combinations.yml for the explicit matrix.

  # rspec: 3.12 (LTS-ish) and 3.13 (current). Default resolves to 3.13.
  gem 'rspec', ENV.fetch('RSPEC_VERSION', '>= 3.12')

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
  # is not committed.
  gem 'mutant-rspec', '~> 0.16' if RUBY_ENGINE == 'ruby' && Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3')

  # Hot-path profiling — MRI only (stackprof relies on rb_postponed_job_*
  # APIs that JRuby + TruffleRuby don't implement). Used by `task
  # profile:*` to identify allocation / wall-clock hot spots in the
  # tracker pipeline. Microbenchmark scenarios under benchmark/scenarios/
  # are wrapped via benchmark/profile.rb's StackProf.run driver; the
  # gem is only required there, never by lib/ code.
  gem 'stackprof', '~> 0.2' if RUBY_ENGINE == 'ruby'
end

gemspec
