# frozen_string_literal: true

require 'etc'

# Resolve the user's home directory without raising at gem-load time. Each
# primitive (Dir.home, Etc.getpwuid.dir, File.expand_path("~user")) can raise
# ArgumentError when HOME is unset and the passwd database has no matching
# entry (common in minimal containers and CI images). Graceful degradation:
# if none resolves, skip global config entirely rather than aborting boot.
home_dir = begin
  Dir.home
rescue ArgumentError
  nil
end

home_dir ||= begin
  Etc.getpwuid.dir
rescue ArgumentError
  nil
end

user = ENV.fetch('USER', nil)
home_dir ||= begin
  File.expand_path("~#{user}") if user
rescue ArgumentError
  nil
end

if home_dir
  global_config_path = File.join(home_dir, '.rspec-tracer')

  load global_config_path if File.exist?(global_config_path)
end
