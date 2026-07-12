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
    Test-dependency intelligence for RSpec: detect flaky tests, map code
    coupling, and -- when you are ready -- re-run only what changed.
  SUMMARY
  spec.description = <<-DESCRIPTION.strip.gsub(/\s+/, ' ')
    RSpec Tracer records the inputs each RSpec example consumes -- using
    Ruby's built-in coverage library plus explicit declarations -- and turns
    that record into a flaky-test detector, a per-example dependency map, and
    optional CI acceleration that skips the examples whose recorded inputs
    are unchanged. It never skips failed, flaky, or pending examples.
  DESCRIPTION
  spec.license = 'MIT'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "https://github.com/avmnu-sng/rspec-tracer/tree/v#{spec.version}"
  spec.metadata['changelog_uri'] = 'https://github.com/avmnu-sng/rspec-tracer/blob/main/CHANGELOG.md'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/avmnu-sng/rspec-tracer/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.required_ruby_version = '>= 3.1.0'

  spec.add_dependency 'docile', '~> 1.4'
  spec.add_dependency 'rspec-core', '~> 3.12'

  spec.files = `git ls-files -- lib/*`.chomp.split("\n")
  spec.files += %w[CHANGELOG.md README.md LICENSE]
  spec.bindir = 'bin'
  spec.executables = ['rspec-tracer']
  spec.require_paths = ['lib']
end
