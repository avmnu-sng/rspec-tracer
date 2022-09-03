# frozen_string_literal: true

require_relative 'configuration'
RSpecTracer.extend RSpecTracer::Configuration

require_relative 'load_default_config'
require_relative 'load_global_config'
require_relative 'load_local_config'

RSpecTracer::Configuration.module_exec do
  (RSpecTracer::Configuration.instance_methods(false) - [:configure]).each do |method_name|
    define_method method_name do |*args|
      send("_#{method_name}".to_sym, *args)
    end
  end
end
