# frozen_string_literal: true

config_path = Pathname.new(RSpecTracer.root)

loop do
  filename = config_path.join('.rspec-tracer')

  if filename.exist?
    load filename

    break
  end

  config_path, = config_path.split

  break if config_path.root?
end
