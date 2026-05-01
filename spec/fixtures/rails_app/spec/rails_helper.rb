# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'

# Enable rspec-tracer for this fixture when RSPEC_TRACER=1 is set (the
# M4.3 integration matrix + the benchmark harness cold_rails_v2 both
# flip this on). Load order matters:
#
#   1. SimpleCov.start (Coverage.start) BEFORE Rails loads, so every
#      framework + app .rb file ends up in the tracker's
#      LoadedFilesTracker boot_set.
#   2. Rails loads (config/environment).
#   3. RSpecTracer.start AFTER Rails is in the object graph, so
#      `setup_rails`'s `defined?(::Rails::VERSION)` check resolves
#      truthy and Engine.setup installs the Rails::Notifications +
#      Rails::I18nTracking observers.
#
# RSPEC_TRACER_FIXTURE_NO_SIMPLECOV=1 opts out of SimpleCov so
# rspec-tracer's own coverage.json emitter writes to
# rspec_tracer_coverage/coverage.json. Used by the
# spec/integration/coverage_json_round_trip_spec.rb golden round-trip
# (when SimpleCov is loaded, rspec-tracer defers coverage emission to
# SimpleCov's at_exit and never writes its own coverage.json).
if ENV['RSPEC_TRACER'] == '1' && ENV['RSPEC_TRACER_FIXTURE_NO_SIMPLECOV'] != '1'
  require 'simplecov'
  SimpleCov.start { add_filter(%r{^/spec/}) } unless SimpleCov.running
end

require_relative '../config/environment'

if ENV['RSPEC_TRACER'] == '1'
  require 'rspec_tracer'
  RSpecTracer.start
end

abort('The Rails environment is running in production mode!') if Rails.env.production?

require 'rspec/rails'
require 'factory_bot_rails'

# Check for pending migrations and auto-run them.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  warn e.to_s.strip
  exit 1
end

require_relative 'spec_helper'

Dir[Rails.root.join('spec/support/**/*.rb')].each { |f| require f }

# Optional DatabaseCleaner driver for the wide-schema integration specs.
# RSPEC_TRACER_DB_CLEANER_STRATEGY = truncation | deletion | transaction
# loads database_cleaner-active_record and wraps each example in a
# DatabaseCleaner.cleaning around hook with the requested strategy. The
# narrow-schema + transactional + non-DSL flows leave the env unset, so
# the gem is never required and the existing Gemfile resolve still works
# on every matrix cell.
db_cleaner_strategy = ENV['RSPEC_TRACER_DB_CLEANER_STRATEGY']
if db_cleaner_strategy && !db_cleaner_strategy.empty?
  require 'database_cleaner/active_record'
  DatabaseCleaner.strategy = db_cleaner_strategy.to_sym
end

RSpec.configure do |config|
  # rspec-rails renamed `fixture_path=` (singular) to `fixture_paths=`
  # (Array) in 6.2. The Rails 7.0 matrix cell pins rspec-rails 6.1, so
  # prefer the newer setter when available and fall back to the older one.
  fixtures_path = Rails.root.join('spec/fixtures').to_s
  if config.respond_to?(:fixture_paths=)
    config.fixture_paths = [fixtures_path]
  elsif config.respond_to?(:fixture_path=)
    config.fixture_path = fixtures_path
  end

  # Default: transactional fixtures on (matches Rails idiomatic test
  # setup; covered by `task test:features:rails`). When the M8.2-B
  # narrow-AR-schema scenario flips RSPEC_TRACER_RAILS_TRANSACTIONAL=false,
  # each example commits its writes to the test DB and the per-example
  # schema-subscriber attribution path (Tracker::Notifications) becomes
  # the only mechanism observing AR schema changes - the canonical
  # use_transactional_fixtures=false case real users with per-example
  # transactions off see. Driven by `task test:features:rails:narrow-schema`.
  config.use_transactional_fixtures = ENV.fetch('RSPEC_TRACER_RAILS_TRANSACTIONAL', 'true') != 'false'
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods
  config.include ActiveSupport::Testing::TimeHelpers

  # When DatabaseCleaner is in play, wrap every opted-in example in a
  # cleaning block. The cleanup queries (TRUNCATE / DELETE /
  # BEGIN..ROLLBACK) fire `sql.active_record` events INSIDE the
  # per-example bucket window - exactly the contamination the
  # wide-schema specs assert on. The hook is opt-in via the
  # `:db_cleaned` metadata so the fixture can express the
  # widening-boundary: AR-touching describes tag `:db_cleaned` and get
  # schema attribution via cleanup events, while pure-compute describes
  # leave the tag off, get no around hook, fire no AR events, and so
  # legitimately do NOT re-run on schema mutation.
  if db_cleaner_strategy && !db_cleaner_strategy.empty?
    config.around(:each, :db_cleaned) do |example|
      DatabaseCleaner.cleaning { example.run }
    end
  end
end
