# frozen_string_literal: true

module RSpecTracer
  # Internal CLI — see {RSpecTracer} for the user-facing surface.
  # @api private
  module CLI
    # `rspec-tracer report:open` — open the HTML report in the default
    # browser. Resolves `report_path/index.html` and dispatches via
    # `open` (macOS) / `xdg-open` (Linux). Falls back to printing the
    # path when no opener is available.
    module ReportOpen
      # @param args [Array<String>] sub-command args (`-h` / `--help`).
      # @param stdout [IO]
      # @param stderr [IO]
      # @return [Integer] exit status (0 = opened or path printed,
      #   1 = report missing).
      def self.run(args, stdout: $stdout, stderr: $stderr)
        return print_help(stdout) if args.include?('-h') || args.include?('--help')

        report_path = RSpecTracer.report_path
        index_path = File.join(report_path, 'index.html')

        unless File.file?(index_path)
          stderr.puts "report:open: no report at #{index_path}"
          stderr.puts '  run rspec first to generate the HTML report'
          return 1
        end

        opener = detect_opener
        if opener.nil?
          stdout.puts "report:open: report at #{index_path}"
          stdout.puts '  no opener detected (open / xdg-open); open the path manually'
          return 0
        end

        launch(opener, index_path, stdout, stderr)
      rescue Errno::EPIPE
        # Downstream pipe (`... | head`) closed early -- routine in
        # shell pipelines, not a failure. Exit 0 silently.
        0
      rescue StandardError => e
        stderr.puts "report:open: #{e.class}: #{e.message}"
        1
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.launch(opener, index_path, stdout, stderr)
        if system(opener, index_path, out: File::NULL, err: File::NULL)
          stdout.puts "report:open: opened #{index_path} via #{opener}"
          0
        else
          stderr.puts "report:open: failed to launch #{opener} #{index_path}"
          1
        end
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.print_help(stdout)
        stdout.puts <<~HELP
          Usage: rspec-tracer report:open

          Open the HTML report (`report_path/index.html`) in the default
          browser. Uses `open` on macOS and `xdg-open` on Linux. Prints
          the path and exits 0 when no opener is available.
        HELP
        0
      end

      # Returns the opener binary name on PATH, or nil. Checked in
      # priority order: macOS `open`, then Linux `xdg-open`. Windows
      # is unsupported per `COMPATIBILITY_MATRIX.md`'s explicit drop;
      # users on Windows see the print-the-path fallback.
      def self.detect_opener
        %w[open xdg-open].find { |bin| which(bin) }
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.which(binary)
        found = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
          path = File.join(dir, binary)
          File.file?(path) && File.executable?(path)
        end
        found ? binary : nil
      end
    end
  end
end
