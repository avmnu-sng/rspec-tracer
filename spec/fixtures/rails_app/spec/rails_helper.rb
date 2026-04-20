# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'

# Enable rspec-tracer for this fixture when RSPEC_TRACER=1 is set (the
# benchmark harness sets this for cold_rails measurements). Left off by
# default so `task fixtures:rails:rspec` and the M4.3 integration tests
# can opt in explicitly.
if ENV['RSPEC_TRACER'] == '1'
  require 'rspec_tracer'
  RSpecTracer.start
end

require_relative '../config/environment'

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
