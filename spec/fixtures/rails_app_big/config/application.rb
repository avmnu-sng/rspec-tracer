# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"

Bundler.require(*Rails.groups)

module RailsApp
  class Application < Rails::Application
    # Resolve "~> 7.1.0" → 7.1 so the scaffold picks up the right
    # generator defaults when the matrix swaps RAILS_VERSION.
    rails_version = ENV.fetch("RAILS_VERSION", "~> 7.1.0")
    config.load_defaults rails_version.sub(/[^\d]*/, "").split(".").first(2).join(".").to_f

    # `config.autoload_lib` is a Rails 7.1+ helper; guard for the
    # Rails 7.0 matrix cell, which still supports the fixture via
    # the manual autoload + eager_load path wiring.
    if config.respond_to?(:autoload_lib)
      config.autoload_lib(ignore: %w[assets tasks])
    else
      lib_path = root.join('lib').to_s
      config.autoload_paths << lib_path
      config.eager_load_paths << lib_path
    end

    config.generators.system_tests = nil

    config.action_mailer.delivery_method = :test
    config.action_mailer.default_url_options = { host: "localhost", port: 3000 }

    config.active_job.queue_adapter = :test
  end
end
