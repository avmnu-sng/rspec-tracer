# frozen_string_literal: true

require 'etc'

home_dir = (ENV['HOME'] && File.expand_path('~'))
home_dir ||= Etc.getpwuid.dir
home_dir ||= (ENV['USER'] && File.expand_path("~#{ENV['USER']}"))

if home_dir
  global_config_path = File.join(home_dir, '.rspec-tracer')

  load global_config_path if File.exist?(global_config_path)
end
