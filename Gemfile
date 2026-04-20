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
  gem 'rspec', '~> 3.13'
  gem 'rubocop', '~> 1.60'
  gem 'rubocop-performance', '~> 1.20'
  gem 'rubocop-rake', '~> 0.6'
  gem 'rubocop-rspec', '~> 3.0'
  gem 'simplecov', '~> 0.22'
  gem 'sprockets', '~> 4.2'
  gem 'uglifier', '~> 4.2'
  gem 'yui-compressor', '~> 0.12'

  # Mutation testing — MRI >= 3.2 only. mutant 0.16.x dropped Ruby 3.1
  # and doesn't target JRuby. `install_if` keeps bundle install quiet
  # on 3.1 / JRuby matrix cells instead of erroring out.
  install_if -> { RUBY_ENGINE == 'ruby' && Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.2') } do
    gem 'mutant-rspec', '~> 0.16'
  end
end

gemspec
