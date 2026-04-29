# frozen_string_literal: true

# Hot-path profile driver. Wraps an existing benchmark scenario in
# StackProf.run and dumps a raw .dump under tmp/profile/<name>.dump.
#
# Usage:
#   bundle exec ruby benchmark/profile.rb <scenario>
#   STACKPROF_MODE=cpu bundle exec ruby benchmark/profile.rb engine
#
# Output:
#   tmp/profile/<scenario>.dump      raw stackprof dump (gitignored)
#   tmp/profile/<scenario>.txt       text summary of top frames
#   tmp/profile/<scenario>.json      flamegraph JSON for speedscope
#
# Inspect:
#   bundle exec stackprof --text tmp/profile/<scenario>.dump | head -40
#   bundle exec stackprof --method '<method-name>' tmp/profile/<scenario>.dump
#   open https://www.speedscope.app and load tmp/profile/<scenario>.json

require 'fileutils'
require 'stackprof'
require 'time'

SCENARIO_SCRIPTS = {
  'io_hooks' => 'benchmark/scenarios/file_read_hook.rb',
  'coverage_adapter' => 'benchmark/scenarios/coverage_adapter.rb',
  'loaded_files' => 'benchmark/scenarios/loaded_files_tracker.rb',
  'cache_load' => 'benchmark/scenarios/cache_load.rb',
  'engine' => 'benchmark/scenarios/engine_microbench.rb'
}.freeze

scenario = ARGV.shift
unless SCENARIO_SCRIPTS.key?(scenario)
  warn 'usage: ruby benchmark/profile.rb <scenario>'
  warn "scenarios: #{SCENARIO_SCRIPTS.keys.join(', ')}"
  exit 1
end

repo_root = File.expand_path('..', __dir__)
script_path = File.expand_path(SCENARIO_SCRIPTS.fetch(scenario), repo_root)
out_dir = File.expand_path('tmp/profile', repo_root)
FileUtils.mkdir_p(out_dir)
dump_path = File.join(out_dir, "#{scenario}.dump")
text_path = File.join(out_dir, "#{scenario}.txt")

mode = (ENV['STACKPROF_MODE'] || 'wall').to_sym
interval = Integer(ENV.fetch('STACKPROF_INTERVAL', '1000'))

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
StackProf.run(mode: mode, raw: true, interval: interval, out: dump_path) do
  load script_path
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

# Text summary — top 25 frames by self time. Captured to a file so the
# PR commit message + PERFORMANCE_NOTES can paste a stable excerpt.
# Marshal.load on stackprof's own dump format is the documented API
# (see stackprof's bin/stackprof); the file is one we just wrote.
report = StackProf::Report.new(
  Marshal.load(File.binread(dump_path)) # rubocop:disable Security/MarshalLoad
)
File.open(text_path, 'w') do |f|
  f.puts "# Profile: #{scenario}  mode=#{mode}  interval=#{interval}us"
  f.puts "# Wall time of profiled run: #{format('%.3f', elapsed)}s"
  f.puts "# Generated: #{Time.now.utc.iso8601}"
  f.puts
  report.print_text(false, 25, nil, nil, nil, nil, f)
end

puts "scenario=#{scenario} mode=#{mode} elapsed=#{format('%.3f', elapsed)}s"
puts "  dump: #{dump_path}"
puts "  text: #{text_path}"
puts "  inspect: bundle exec stackprof --text #{dump_path} | head -40"
puts "  flame:   bundle exec stackprof --stackcollapse #{dump_path} > #{dump_path}.stacks"
