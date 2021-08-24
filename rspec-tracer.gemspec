# frozen_string_literal: true

$LOAD_PATH.push File.expand_path('lib', __dir__)

require 'rspec_tracer/version'

Gem::Specification.new do |spec|
  spec.name = 'rspec-tracer'
  spec.version = RSpecTracer::VERSION
  spec.authors = ['Abhimanyu Singh']
  spec.email = ['abhisinghabhimanyu@gmail.com']

  spec.homepage = 'https://github.com/avmnu-sng/rspec-tracer'
  spec.summary = 'RSpec Examples Dependencies Tracker'
  spec.description = <<-DESC.strip.gsub(/\s+/, ' ')
    Generates dependencies of each of the RSpec examples enabling
    running specs for the code having dependencies changed.
  DESC
  spec.license = 'MIT'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "https://github.com/avmnu-sng/rspec-tracer/tree/v#{spec.version}"
  spec.metadata['changelog_uri'] = 'https://github.com/avmnu-sng/rspec-tracer/blob/main/CHANGELOG.md'
  spec.metadata['bug_tracker_uril'] = 'https://github.com/avmnu-sng/rspec-tracer/issues'

  spec.required_ruby_version = '>= 2.5.0'

  spec.add_dependency 'docile', '~> 1.1.0'
  spec.add_dependency 'rspec-core', '>= 3.6.0'

  spec.files = Dir['{lib}/**/*.*', 'LICENSE', 'CHANGELOG.md', 'README.md', 'doc/*']
  spec.require_paths = ['lib']
end
