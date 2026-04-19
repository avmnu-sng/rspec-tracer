# frozen_string_literal: true

require 'bundler'
Bundler.setup

require 'simplecov'
require 'simplecov_json_formatter'

SimpleCov.formatters = [
  SimpleCov::Formatter::HTMLFormatter,
  SimpleCov::Formatter::JSONFormatter
].freeze

SimpleCov.start do
  enable_coverage :branch if ENV.fetch('BRANCH_COVERAGE', 'false') == 'true'

  add_filter %w[/features/ /spec/ /tmp/]
end

require 'aruba/cucumber'
require 'pry'
require 'tmpdir'

# CI runners configured with `bundler-cache: true` (e.g. ruby/setup-ruby@v1)
# write `.bundle/config` at the repo root with BUNDLE_DEPLOYMENT=true and
# BUNDLE_PATH=vendor/bundle. Bundler walks up the directory tree from the
# subprocess cwd (tmp/aruba/project/...), finds that config, and forces
# deployment mode where Gemfile.lock must exist and match exactly. The sample
# projects under features do not ship a Gemfile.lock, so `bundle install`
# (and subsequent `bundle exec`) fail with "Could not find gem X in locally
# installed gems". Redirect bundler to read app-level config from an
# isolated empty directory so subprocess bundler uses defaults.
Before('@disable-bundler') do
  isolated_bundle_config = File.join(Dir.tmpdir, "aruba-bundle-config-#{Process.pid}")
  FileUtils.mkdir_p(isolated_bundle_config)
  set_environment_variable('BUNDLE_APP_CONFIG', isolated_bundle_config)
end

# Tagged `@disable-bundler` so this runs AFTER aruba's hook that scrubs
# BUNDLE_* and the `-rbundler/setup` fragment from `RUBYOPT`. If a future
# feature drops `@disable-bundler`, the scrub doesn't happen — we'd
# otherwise prepend `-r<setup>` onto `-rbundler/setup`, re-injecting
# bundler/setup into the subprocess and forcing `Bundler.setup` against
# the parent Gemfile.lock (the exact failure this hook is working
# around).
Before('@disable-bundler') do
  next unless ENV.fetch('SKIP_COVERAGE_VALIDATION', 'false') == 'true'

  setup_file = File.join(File.expand_path('../..', __dir__), 'support', 'coverage_setup')

  case RUBY_ENGINE
  when 'ruby'
    existing_rubyopt = aruba.environment['RUBYOPT'].to_s
    set_environment_variable('RUBYOPT', "-r#{setup_file} #{existing_rubyopt}".strip)
  when 'jruby'
    existing_jruby_opts = aruba.environment['JRUBY_OPTS'].to_s
    set_environment_variable('JRUBY_OPTS', "--debug -X+O -r#{setup_file} #{existing_jruby_opts}".strip)
  end
end

Before('@branch-coverage') do
  skip_this_scenario unless ENV.fetch('BRANCH_COVERAGE', 'false') == 'true'
end
