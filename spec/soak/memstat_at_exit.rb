# frozen_string_literal: true

# Loaded into the rspec-tracer-instrumented soak subprocess via
# RUBYOPT="-r<absolute_path>/memstat_at_exit.rb". On exit, writes a
# memory snapshot under `$SOAK_MEMSTAT_DIR/memstat-<pid>.json`.
#
# The soak parent (spec/soak/rails_app_soak_spec.rb) reads the
# memstat with the largest `total_memsize` across all PIDs in
# `iter-<N>/`; that filters out the bundler / shell wrapper PIDs
# (tiny) and gives us the actual rspec process's memory state at
# its exit.
#
# Graceful-degradation: any failure inside the at_exit handler is
# captured to a sibling `.error` file and never propagates to the
# subprocess's exit status. The soak's signal is memstat-vs-baseline,
# not "did the at_exit handler succeed."

require 'json'
require 'objspace'

at_exit do
  dir = ENV.fetch('SOAK_MEMSTAT_DIR', nil)
  next if dir.nil? || dir.empty?

  begin
    snapshot = {
      'pid' => Process.pid,
      'ppid' => Process.ppid,
      'time' => Time.now.to_f,
      'gc_stat' => GC.stat,
      'count_objects' => ObjectSpace.count_objects,
      'total_memsize' => ObjectSpace.memsize_of_all,
      'argv0' => $PROGRAM_NAME
    }

    target = File.join(dir, "memstat-#{Process.pid}.json")
    File.write(target, JSON.pretty_generate(snapshot))
  rescue StandardError => e
    err_target = File.join(dir, "memstat-#{Process.pid}.error")
    begin
      File.write(err_target, "#{e.class}: #{e.message}")
    rescue StandardError
      nil
    end
  end
end
