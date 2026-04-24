# frozen_string_literal: true

source 'https://rubygems.org'

group :development do
  gem 'pry', '~> 0.14'
  gem 'rake', '~> 13.0'
  gem 'rspec', '~> 3.10'
  gem 'simplecov', '~> 0.21'

  # Rubocop chain requires Ruby >= 2.7 for recent releases. The
  # conditional (rather than a separate group with BUNDLE_WITHOUT) is
  # load-bearing: `bundle install --without` still resolves skipped
  # groups and validates their `required_ruby_version`, which aborts
  # Ruby 2.5 / 2.6 cells. Dropping rubocop from the Gemfile entirely
  # on those Rubies is the only reliable way. lint.yml runs on Ruby
  # 3.4 so this gate doesn't reduce lint coverage.
  if RUBY_VERSION >= '2.7.0'
    gem 'rubocop', '~> 1.60'
    gem 'rubocop-performance', '~> 1.20'
    gem 'rubocop-rake', '~> 0.6'
    gem 'rubocop-rspec', '~> 3.0'
  end
end

# Cucumber stack — only needed for feature-spec workflows. Split out
# of :development so spec.yml / lint.yml can `--without cucumber` and
# skip the aruba 2.0 / cucumber 7.0 chain that caps `bundler < 3`,
# which otherwise fails resolution on Ruby 4.0 (ships Bundler 4 as a
# default gem).
#
# Cucumber 7.x's `multiline_argument/data_table.rb` passes `:strict` /
# `:proc` as kwargs to `Hash.new`, which Ruby 3.4+ rejects
# (ArgumentError: unknown keywords). Bump to cucumber 9.x (+ aruba 2.2)
# on Ruby 3.4+; keep 7.x on older Rubies (cucumber 9.x drops Ruby < 3.0).
group :cucumber do
  if RUBY_VERSION >= '3.4.0'
    gem 'aruba', '~> 2.2'
    gem 'cucumber', '~> 9.2'
  else
    gem 'aruba', '~> 2.0'
    gem 'cucumber', '~> 7.0'
  end
  gem 'parallel_tests', '~> 3.7'
  gem 'sprockets', '~> 4.0'
  gem 'uglifier', '~> 4.2'
  gem 'yui-compressor', '~> 0.12'
end

gemspec
