# frozen_string_literal: true

require_relative 'base'

module RSpecTracer
  module Reporters
    # Concise stdout summary printed at finalize-time. Output is
    # capped at 4 lines for a typical run (5 when duplicate /
    # interrupted / flaky / pending counters are non-zero). Kind-less
    # taxonomy by design - the in-memory Input#kind enum does not
    # survive Storage::Snapshot persistence, so breaking down
    # "Changed files: Templates / Locales / Ruby" would require a
    # schema bump (deferred).
    #
    # Color policy:
    #   - Respects `NO_COLOR` per https://no-color.org/ (any value
    #     disables, even empty string).
    #   - Emits ANSI codes only when the output stream reports tty?.
    #   - The header line paints red on any failure / interrupted,
    #     yellow on pending-only, green otherwise.
    class TerminalReporter < Base
      COLORS = {
        reset: 0,
        red: 31,
        green: 32,
        yellow: 33,
        cyan: 36
      }.freeze
      private_constant :COLORS

      # "\u00B7" = U+00B7 MIDDLE DOT. Written as the ASCII escape form
      # so mutant's US-ASCII-defaulted parser doesn't choke on
      # non-ASCII bytes in the source file. Same discipline as the
      # dependency_graph.rb workaround.
      SEPARATOR = " \u00B7 "
      private_constant :SEPARATOR

      # Snapshot-set-name => human label pairs for the tally line.
      # Data-driven to keep tally_line's AbcSize below rubocop's
      # threshold; new counters go here without growing the method.
      TALLY_FIELDS = [
        [:failed_examples, 'failed'],
        [:pending_examples, 'pending'],
        [:flaky_examples, 'flaky'],
        [:interrupted_examples, 'interrupted']
      ].freeze
      private_constant :TALLY_FIELDS

      BYTES_PER_MIB = 1_048_576.0
      private_constant :BYTES_PER_MIB

      def generate
        return nil if no_op?

        lines = build_lines
        stream = output_stream
        lines.each { |line| stream.puts line }
        lines
      end

      private

      def build_lines
        [header_line, tally_line, kind_breakdown_line, cache_line, report_line].compact
      end

      def header_line
        total = snapshot.all_examples.size
        run = run_count
        skipped = snapshot.skipped_examples.size
        cached_pct = cache_percent(total, skipped)

        text = "rspec-tracer: #{total} examples tracked" \
               "#{SEPARATOR}#{run} re-run#{SEPARATOR}#{skipped} skipped " \
               "(#{cached_pct}% cached)"
        paint(header_color, text)
      end

      def tally_line
        parts = TALLY_FIELDS.filter_map do |field, label|
          ids = snapshot.send(field)
          "#{ids.size} #{label}" unless ids.empty?
        end
        parts << "#{duplicate_count} duplicate" if duplicate_count.positive?
        return nil if parts.empty?

        paint(:yellow, parts.join(SEPARATOR))
      end

      def cache_line
        path = run_metadata[:cache_path]
        return nil if path.nil? || path.to_s.empty?

        size_part = cache_size_suffix(path.to_s)
        "cache: #{path}#{size_part}"
      end

      # Per-reason breakdown of the run examples (e.g. 12 Files
      # changed · 5 No cache). Sourced from snapshot.cache_hit_reason
      # which the engine populated via @filtered_examples.values.tally
      # at finalize. Empty {} (cold run with no engine cache) suppresses
      # the line entirely. Sorted by count descending so the
      # most-impactful reason leads.
      def kind_breakdown_line
        reasons = snapshot.cache_hit_reason
        return nil if reasons.nil? || reasons.empty?

        parts = reasons
          .sort_by { |_reason, count| -count.to_i }
          .map { |reason, count| "#{count} #{reason}" }
        paint(:cyan, "by reason: #{parts.join(SEPARATOR)}")
      end

      # Bytes -> "12.3 MiB" / "456 KiB" / "789 B" depending on order.
      # Mirrors JsonBackend#format_mib's MiB-and-up presentation but
      # collapses small caches to KiB so a fixture spec writing 4 KiB
      # doesn't display as "0.0 MiB."
      def format_size_bytes(bytes)
        return "#{bytes} B" if bytes < 1024
        return "#{(bytes / 1024.0).round(1)} KiB" if bytes < BYTES_PER_MIB

        "#{(bytes / BYTES_PER_MIB).round(1)} MiB"
      end

      # `(<size>)` or `(<size>; <delta>)` suffix for the cache line.
      # Walks the current run-id dir for the size; walks the prior
      # run-id dir (mtime-newest peer) for the delta. Wrapped in
      # rescue so a transient FS error never blocks the surrounding
      # cache_line emission.
      def cache_size_suffix(cache_path)
        current_id = snapshot.run_id
        return '' if current_id.nil? || current_id.to_s.empty?

        current_dir = File.join(cache_path, current_id)
        return '' unless File.directory?(current_dir)

        current_bytes = directory_size_bytes(current_dir)
        prior_bytes = previous_run_dir_bytes(cache_path, current_id)
        format_cache_suffix(current_bytes, prior_bytes)
      rescue StandardError
        ''
      end

      def format_cache_suffix(current_bytes, prior_bytes)
        size = format_size_bytes(current_bytes)
        return " (#{size})" if prior_bytes.nil?

        delta = current_bytes - prior_bytes
        sign = if delta.positive?
                 '+'
               else
                 (delta.negative? ? '-' : '')
               end
        " (#{size}; #{sign}#{format_size_bytes(delta.abs)} vs prev run)"
      end

      def directory_size_bytes(dir)
        Dir[File.join(dir, '**', '*')].sum do |path|
          File.file?(path) ? File.size(path) : 0
        end
      end

      def previous_run_dir_bytes(cache_path, current_id)
        peer_dirs = Dir.children(cache_path).filter_map do |name|
          next if name == current_id || name.start_with?('.')

          full = File.join(cache_path, name)
          File.directory?(full) ? [full, File.mtime(full).to_f] : nil
        end
        return nil if peer_dirs.empty?

        newest_peer = peer_dirs.max_by(&:last).first
        directory_size_bytes(newest_peer)
      end

      def report_line
        return nil if report_dir.nil? || report_dir.to_s.empty?

        "report: #{File.join(report_dir, JsonReporter::FILENAME)}"
      end

      def header_color
        return :red if snapshot.failed_examples.any? || snapshot.interrupted_examples.any?
        return :yellow if snapshot.pending_examples.any?

        :green
      end

      def run_count
        snapshot.all_examples.count do |_, meta|
          meta.is_a?(::Hash) && meta[:execution_result]
        end
      end

      def duplicate_count
        snapshot.duplicate_examples.size
      end

      def cache_percent(total, skipped)
        return 0 if total.zero?

        ((skipped.to_f / total) * 100).round
      end

      def paint(color_key, text)
        return text unless use_color?

        code = COLORS.fetch(color_key, COLORS[:reset])
        "\e[#{code}m#{text}\e[#{COLORS[:reset]}m"
      end

      def use_color?
        return false if ENV.key?('NO_COLOR')

        output_stream.respond_to?(:tty?) && output_stream.tty?
      end

      def output_stream
        options[:io] || $stdout
      end
    end
  end
end
