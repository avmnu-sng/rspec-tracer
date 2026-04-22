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
if ENV['RSPEC_TRACER'] == '1'
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

RSpec.configure do |config|
  config.fixture_paths = [ Rails.root.join('spec/fixtures').to_s ]
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods
  config.include ActiveSupport::Testing::TimeHelpers
end
