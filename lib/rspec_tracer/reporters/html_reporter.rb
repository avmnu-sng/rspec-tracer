# frozen_string_literal: true

require 'cgi'
require 'fileutils'
require 'json'

require_relative 'base'
require_relative 'payload_builder'

module RSpecTracer
  # Internal Reporters — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Reporters
    # Renders a single-page HTML report at `<report_dir>/index.html`
    # consuming the canonical payload built by `PayloadBuilder`
    # (shared with `JsonReporter`).
    #
    # Build output - the frontend bundle at
    # `lib/rspec_tracer/reporters/html/dist/` - is committed to the
    # repo; users never run npm. At emit time this reporter:
    #
    #   1. Reads the template at `html/dist/index.html`.
    #   2. Replaces the `<!-- RSPEC_TRACER_FALLBACK -->` marker with
    #      server-rendered `<table>` HTML for each of the 5 report
    #      types (satisfies the "works without JavaScript" AC; the
    #      Preact bundle removes these on hydrate).
    #   3. Replaces the body of `<script id="report-data">` with the
    #      full payload JSON.
    #   4. Copies `html/dist/assets/` next to the output.
    #   5. Writes the finished file.
    #
    # Failure modes are graceful: the Registry wraps `#generate` in
    # an isolated rescue, so a template-missing or template-corrupt
    # condition logs a warning and returns nil rather than propagating
    # a non-zero exit into the user's test suite.
    class HtmlReporter < Base
      # Internal constant.
      # @api private
      FILENAME = 'index.html'
      # Internal constant.
      # @api private
      ASSETS_DIR = 'assets'
      # Internal constant.
      # @api private
      FALLBACK_MARKER = '<!-- RSPEC_TRACER_FALLBACK -->'
      # Internal constant.
      # @api private
      REPORT_DATA_REGEX = %r{<script id="report-data" type="application/json">.*?</script>}m

      # Absolute path to the committed frontend build under
      # `lib/rspec_tracer/reporters/html/dist/`. Computed once at load
      # time so tests can stub `DIST_DIR` if they need a different
      # template root.
      DIST_DIR = File.expand_path('html/dist', __dir__)

      # Concrete implementation of {RSpecTracer::Reporters::Base#generate}.
      # Renders the bundled HTML template with the run payload and writes
      # `index.html` (plus the asset directory) under {#report_dir}.
      #
      # @return [String, nil] absolute path of the written index, or nil
      #   when there is nothing to render.
      def generate
        return nil if no_op?

        template = read_template
        return nil if template.nil?

        payload_json = PayloadBuilder.build(
          snapshot: snapshot,
          run_metadata: run_metadata,
          generated_at: generated_at_override
        )
        rendered = inject(template, payload_json)

        FileUtils.mkdir_p(report_dir)
        copy_assets
        path = File.join(report_dir, FILENAME)
        File.write(path, rendered, encoding: 'UTF-8')
        logger&.debug("rspec-tracer: wrote HTML report to #{path}")
        path
      end

      private

      # Internal method on the tracer pipeline.
      # @api private
      def read_template
        path = File.join(dist_dir, FILENAME)
        return File.read(path, encoding: 'UTF-8') if File.file?(path)

        logger&.warn("rspec-tracer: HTML template missing at #{path}; HTML report not emitted")
        nil
      end

      # Internal method on the tracer pipeline.
      # @api private
      def inject(template, payload)
        with_payload = template.sub(
          REPORT_DATA_REGEX,
          %(<script id="report-data" type="application/json">#{escape_payload(payload)}</script>)
        )
        with_payload.sub(FALLBACK_MARKER, render_fallback(payload))
      end

      # The payload sits inside a `<script>` tag. To make it inert as
      # HTML we escape `<`, `>`, and `&` with JSON-safe `\uXXXX`
      # escapes. The string remains valid JSON on round-trip because
      # JSON accepts `\u003c` etc. for any code point.
      def escape_payload(payload)
        JSON.generate(payload).gsub('<', '\\u003c').gsub('>', '\\u003e').gsub('&', '\\u0026')
      end

      # Internal method on the tracer pipeline.
      # @api private
      def render_fallback(payload)
        sections = fallback_sections(payload[:reports] || {})
        %(<div id="fallback" class="fallback-root">#{sections.join("\n")}</div>)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def fallback_sections(reports)
        dups = reports[:duplicate_examples] || []
        flakies = reports[:flaky_examples] || []
        sections = [fallback_all_examples(reports[:all_examples] || [])]
        sections << fallback_duplicate_examples(dups) if dups.any?
        sections << fallback_flaky_examples(flakies) if flakies.any?
        sections << fallback_examples_dependency(reports[:examples_dependency] || [])
        sections << fallback_files_dependency(reports[:files_dependency] || [])
        sections
      end

      # Internal method on the tracer pipeline.
      # @api private
      def fallback_all_examples(items)
        headers = ['Description', 'Location', 'Status', 'Run reason', 'Result', 'Duration']
        rows = items.map do |item|
          result = item[:execution_result] || {}
          cells = [
            cell(item[:description]), cell_code(item[:location]),
            cell(item[:status]), cell(item[:run_reason]),
            cell(result[:status]), cell(format_duration(result[:run_time]))
          ].join
          "<tr>#{cells}</tr>"
        end
        fallback_table('all-examples', 'All Examples', headers, rows)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def fallback_duplicate_examples(items)
        headers = ['Example ID', 'Occurrences', 'Description', 'Location']
        rows = items.flat_map do |group|
          (group[:entries] || []).map do |entry|
            cells = [cell_code(group[:id]), cell(group[:count]),
                     cell(entry[:description]), cell_code(entry[:location])].join
            "<tr>#{cells}</tr>"
          end
        end
        fallback_table('duplicate-examples', 'Duplicate Examples', headers, rows)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def fallback_flaky_examples(items)
        headers = ['Example ID', 'Description', 'Location']
        rows = items.map do |item|
          cells = [cell_code(item[:id]), cell(item[:description]), cell_code(item[:location])].join
          "<tr>#{cells}</tr>"
        end
        fallback_table('flaky-examples', 'Flaky Examples', headers, rows)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def fallback_examples_dependency(items)
        headers = ['Example ID', 'Files', 'Env keys', 'Dependencies']
        rows = items.map do |item|
          files = item[:files] || []
          env_keys = item[:env_keys] || []
          deps = (files + env_keys.map { |k| "env:#{k}" }).map { |d| CGI.escapeHTML(d.to_s) }.join('<br>')
          cells = [cell_code(item[:example_id]), cell(files.size), cell(env_keys.size),
                   %(<td class="cell-deps">#{deps}</td>)].join
          "<tr>#{cells}</tr>"
        end
        fallback_table('examples-dependency', 'Examples Dependency', headers, rows)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def fallback_files_dependency(items)
        headers = ['File', 'Examples', 'Spec files', 'Dependent spec files']
        rows = items.map do |item|
          spec_files = item[:spec_files] || {}
          deps = spec_files.map { |spec, count| "#{CGI.escapeHTML(spec.to_s)} (#{count})" }.join('<br>')
          cells = [cell_code(item[:file_name]), cell(item[:example_count]), cell(spec_files.size),
                   %(<td class="cell-deps">#{deps}</td>)].join
          "<tr>#{cells}</tr>"
        end
        fallback_table('files-dependency', 'Files Dependency', headers, rows)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def fallback_table(id, title, headers, rows)
        header_cells = headers.map { |h| "<th scope=\"col\">#{CGI.escapeHTML(h)}</th>" }.join
        body = rows.empty? ? %(<tr><td colspan="#{headers.size}">No rows.</td></tr>) : rows.join
        <<~HTML
          <section class="fallback-section" id="fallback-#{id}">
            <h2>#{CGI.escapeHTML(title)}</h2>
            <table class="fallback-table">
              <thead><tr>#{header_cells}</tr></thead>
              <tbody>#{body}</tbody>
            </table>
          </section>
        HTML
      end

      # Internal method on the tracer pipeline.
      # @api private
      def cell(value)
        "<td>#{CGI.escapeHTML(value.to_s)}</td>"
      end

      # Internal method on the tracer pipeline.
      # @api private
      def cell_code(value)
        "<td><code>#{CGI.escapeHTML(value.to_s)}</code></td>"
      end

      # Internal method on the tracer pipeline.
      # @api private
      def format_duration(seconds)
        return '' unless seconds.is_a?(::Numeric)
        return format('%d us', (seconds * 1_000_000).round) if seconds < 0.001
        return format('%.1f ms', seconds * 1000) if seconds < 1

        format('%.3f s', seconds)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def copy_assets
        src = File.join(dist_dir, ASSETS_DIR)
        return unless File.directory?(src)

        dest = File.join(report_dir, ASSETS_DIR)
        FileUtils.rm_rf(dest)
        FileUtils.mkdir_p(dest)
        FileUtils.cp_r(Dir[File.join(src, '*')], dest)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def dist_dir
        options[:dist_dir] || DIST_DIR
      end

      # Internal method on the tracer pipeline.
      # @api private
      def generated_at_override
        options[:generated_at]
      end
    end
  end
end
