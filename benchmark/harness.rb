# frozen_string_literal: true

# Placeholder benchmark harness. The real implementation lands in M2.4.
# For M2.1, this exists so `task benchmark:smoke` and `task benchmark:full`
# exit 0, keeping the `task check` feedback loop green.

require 'optparse'

options = { mode: nil, ratchet: nil }

OptionParser.new do |opts|
  opts.banner = 'Usage: ruby benchmark/harness.rb [--smoke | --full] [--ratchet PATH]'
  opts.on('--smoke', 'Run smoke benchmark (placeholder)') { options[:mode] = :smoke }
  opts.on('--full', 'Run full benchmark (placeholder)') { options[:mode] = :full }
  opts.on('--ratchet PATH', 'Ratchet thresholds file (placeholder)') { |p| options[:ratchet] = p }
end.parse!

case options[:mode]
when :smoke
  puts 'benchmark/harness.rb: smoke placeholder — real harness lands in M2.4'
when :full
  puts 'benchmark/harness.rb: full placeholder — real harness lands in M2.4'
  puts "ratchet: #{options[:ratchet]}" if options[:ratchet]
else
  warn 'benchmark/harness.rb: no mode specified (--smoke or --full)'
  exit 1
end
