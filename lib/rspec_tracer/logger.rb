# frozen_string_literal: true

module RSpecTracer
  class Logger
    def initialize(log_level)
      @log_level = log_level
    end

    def debug(message)
      puts message if @log_level == 1
    end

    def info(message)
      puts message if @log_level.between?(1, 2)
    end

    def warn(message)
      puts message if @log_level.between?(1, 3)
    end

    def error(message)
      puts message if @log_level.between?(1, 4)
    end
  end
end
