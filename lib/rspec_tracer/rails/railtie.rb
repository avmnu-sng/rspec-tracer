# frozen_string_literal: true

module RSpecTracer
  module Rails
    # Rails lifecycle adapter. Only required by `lib/rspec_tracer/rails.rb`
    # when `defined?(::Rails::Railtie)` is true, so loading this file in
    # a non-Rails process is not expected and will raise NameError.
    #
    # M4.1 scope: define the Railtie class + register one initializer
    # that logs a single confirmation line. M4.2 fills in
    # ActiveSupport::Notifications subscribers for ActionView template
    # renders, I18n lookups, and schema/factory/fixture tracking.
    class Railtie < ::Rails::Railtie
      initializer 'rspec_tracer.setup' do
        RSpecTracer.logger.info 'rspec-tracer Rails integration loaded'
      end
    end
  end
end
