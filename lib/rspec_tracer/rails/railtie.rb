# frozen_string_literal: true

module RSpecTracer
  module Rails
    # Rails lifecycle adapter. Only required by `lib/rspec_tracer/rails.rb`
    # when `defined?(::Rails::Railtie)` is true, so loading this file in
    # a non-Rails process is not expected and will raise NameError.
    #
    # Defines the Railtie class + registers one initializer that logs
    # a single confirmation line. The actual ActiveSupport::Notifications
    # subscribers for ActionView template renders, I18n lookups, and
    # schema/factory/fixture tracking live in `notifications.rb` and
    # `i18n_tracking.rb` and are wired by `Engine.setup`.
    class Railtie < ::Rails::Railtie
      initializer 'rspec_tracer.setup' do
        RSpecTracer.logger.info 'rspec-tracer Rails integration loaded'
      end
    end
  end
end
