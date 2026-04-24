# frozen_string_literal: true

source 'https://rubygems.org'

group :development do
  gem 'aruba', '~> 2.2'
  gem 'cucumber', '~> 9.2'
  # parallel 2.0+ requires Ruby >= 3.3; pin for Ruby 3.1/3.2 compatibility
  gem 'parallel', '~> 1.26'
  gem 'parallel_tests', '~> 4.7'
  gem 'pry', '~> 0.14'
  gem 'rake', '~> 13.2'
  gem 'rantly', '~> 2.0'
  # redis is a dev dep so we can exercise RedisBackend's real wire path
  # in the integration spec (spec/integration/remote_cache_spec.rb)
  # against a localhost Redis service, and so the lazy `require 'redis'`
  # path in the backend file is exercisable in unit specs. End users
  # who want RedisBackend add the gem to their OWN Gemfile - we do not
  # ship it as a runtime dep per USER_FACING_SURFACE.md.
  gem 'redis', '~> 5.3'
  # connection_pool is a transitive dep of redis-client. 3.x requires
  # Ruby >= 3.2, which breaks our Ruby 3.1 + JRuby 9.4 matrix cells
  # at `bundle install` time. redis-client accepts any connection_pool
  # version, so pinning 2.x here keeps the whole matrix installable.
  gem 'connection_pool', '~> 2.5'
  gem 'rspec', '~> 3.13'
  gem 'rubocop', '~> 1.60'
  gem 'rubocop-performance', '~> 1.20'
  gem 'rubocop-rake', '~> 0.6'
  gem 'rubocop-rspec', '~> 3.0'
  gem 'simplecov', '~> 0.22'
  # msgpack is a dev dep so json_backend_msgpack_spec exercises the real
  # wire path (encode -> zlib deflate -> disk -> inflate -> decode). End
  # users who want the :msgpack serializer add `gem 'msgpack'` to their
  # own Gemfile - we do not ship it as a runtime dep per
  # USER_FACING_SURFACE.md's optional-dep convention.
  gem 'msgpack', '~> 1.7'
  # sqlite3 is a dev dep so spec/storage/sqlite_backend_spec exercises
  # the real DB write/read path on every MRI matrix cell (3.1 - 4.0).
  # Pinned to the 1.x line because sqlite3 2.x declares
  # required_ruby_version >= 3.2 and would break the Ruby 3.1 cell at
  # bundle-install time; a per-Ruby Gemfile conditional would need a
  # per-cell lockfile which conflicts with ruby/setup-ruby@v1's frozen
  # bundler-cache. SqliteBackend uses only the stable sqlite3 API
  # (Database.new / execute / get_first_row / transaction(:immediate))
  # that is identical across 1.x and 2.x; end users on Ruby >= 3.2 who
  # pin `gem 'sqlite3', '~> 2.0'` in their own Gemfile exercise the
  # 2.x path unchanged. JRuby uses a different driver entirely; skip.
  install_if -> { RUBY_ENGINE == 'ruby' } do
    gem 'sqlite3', '~> 1.7'
  end
  gem 'sprockets', '~> 4.2'
  gem 'uglifier', '~> 4.2'
  gem 'yui-compressor', '~> 0.12'

  # Mutation testing — MRI >= 3.3 only. mutant 0.16's own README says
  # "3.2+", but its transitive dep `unparser 0.9.0` declares
  # `required_ruby_version >= 3.3`, so bundle install fails on Ruby
  # 3.2 despite mutant's claim. Also doesn't target JRuby. `install_if`
  # keeps bundle install quiet on 3.1 / 3.2 / JRuby cells.
  install_if -> { RUBY_ENGINE == 'ruby' && Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3') } do
    gem 'mutant-rspec', '~> 0.16'
  end
end

gemspec
