# frozen_string_literal: true

$LOAD_PATH.push File.expand_path('lib', __dir__)

require 'rspec_tracer/version'

Gem::Specification.new do |spec|
  spec.name = 'rspec-tracer'
  spec.version = RSpecTracer::VERSION
  spec.authors = ['Abhimanyu Singh']
  spec.email = ['abhisinghabhimanyu@gmail.com']

  spec.homepage = 'https://github.com/avmnu-sng/rspec-tracer'
  spec.summary = <<-SUMMARY.strip.gsub(/\s+/, ' ')
    RSpec Tracer is a specs dependency analyzer, flaky tests detector, tests
    accelerator, and coverage reporter tool.
  SUMMARY
  spec.description = <<-DESCRIPTION.strip.gsub(/\s+/, ' ')
    RSpec Tracer is a specs dependency analyzer, flaky tests detector, tests
    accelerator, and coverage reporter tool for RSpec. It maintains a list of
    files for each test, enabling itself to skip tests in the subsequent runs
    if none of the dependent files are changed. It uses Ruby's built-in coverage
    library to keep track of the coverage for each test.
  DESCRIPTION
  spec.license = 'MIT'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "https://github.com/avmnu-sng/rspec-tracer/tree/v#{spec.version}"
  spec.metadata['changelog_uri'] = 'https://github.com/avmnu-sng/rspec-tracer/blob/main/CHANGELOG.md'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/avmnu-sng/rspec-tracer/issues'

  spec.required_ruby_version = '>= 2.5.0'

  spec.add_dependency 'docile', '~> 1.1', '>= 1.1.0'
  spec.add_dependency 'rspec-core', '~> 3.6', '>= 3.6.0'

  spec.files = `git ls-files -- lib/*`.chomp.split("\n")
  spec.files += %w[CHANGELOG.md README.md LICENSE]
  spec.require_paths = ['lib']
end
