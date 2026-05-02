# frozen_string_literal: true

require 'json'

module RSpecTracer
  module CLI
    # `rspec-tracer explain <example>` — show why a given example is
    # scheduled to run or skip on the next rspec invocation. Reads the
    # most recent run's JSON files (all_examples.json + dependency.json
    # + failed_examples.json + flaky_examples.json) to surface the
    # dependency set, last-run status, and the run-decision reason.
    module Explain
      def self.run(args, stdout: $stdout, stderr: $stderr)
        return print_help(stdout) if args.empty? || args.include?('-h') || args.include?('--help')

        require 'rspec_tracer/load_config'
        cache_path = RSpecTracer.cache_path

        run_dir = resolve_run_dir(cache_path, stderr)
        return 1 if run_dir.nil?

        all_examples = read_json(File.join(run_dir, 'all_examples.json'))
        match = find_example(all_examples, args.first)
        return no_match(args.first, all_examples, stderr) if match.nil?

        print_explanation(stdout, match, run_dir)
        0
      rescue StandardError => e
        stderr.puts "explain: #{e.class}: #{e.message}"
        1
      end

      def self.resolve_run_dir(cache_path, stderr)
        last_run_path = File.join(cache_path, 'last_run.json')
        unless File.file?(last_run_path)
          stderr.puts "explain: no last_run.json at #{cache_path} — run rspec first"
          return nil
        end

        run_id = JSON.parse(File.read(last_run_path, encoding: 'UTF-8'))['run_id']
        run_dir = File.join(cache_path, run_id.to_s)
        unless File.directory?(run_dir)
          stderr.puts "explain: run_id #{run_id} directory missing at #{run_dir}"
          return nil
        end

        run_dir
      end

      def self.no_match(query, all_examples, stderr)
        stderr.puts "explain: no example matching #{query.inspect}"
        stderr.puts "  cache has #{all_examples.size} examples; pass an example_id or substring of description"
        1
      end

      def self.print_help(stdout)
        stdout.puts <<~HELP
          Usage: rspec-tracer explain <example_id_or_substring>

          Show why an example is scheduled to run or skip. Matches against
          example_id exactly first, then falls back to a substring match
          on the example's full_description. Requires a prior rspec run.
        HELP
        0
      end

      def self.read_json(path)
        return {} unless File.file?(path)

        parsed = JSON.parse(File.read(path, encoding: 'UTF-8'))
        parsed.is_a?(Hash) ? parsed : {}
      end

      def self.find_example(all_examples, query)
        return all_examples[query] if all_examples.key?(query)

        all_examples.find do |id, meta|
          meta = {} unless meta.is_a?(::Hash)
          desc = meta['full_description'] || meta['description'] || ''
          id.include?(query) || desc.include?(query)
        end&.last
      end

      def self.print_explanation(stdout, meta, run_dir)
        meta = {} unless meta.is_a?(::Hash)
        format_lines(meta).each { |line| stdout.puts line }
        print_dependency_summary(stdout, meta, run_dir)
      end

      def self.format_lines(meta)
        id = first_non_nil(meta, 'example_id', 'id') || '<unknown>'
        file = first_non_nil(meta, 'rerun_file_name', 'file_name')
        line = first_non_nil(meta, 'rerun_line_number', 'line_number')
        status = meta.dig('execution_result', 'status') || meta['status'] || 'unknown'
        [
          "id:           #{id}",
          "description:  #{first_non_nil(meta, 'full_description', 'description')}",
          "location:     #{file}:#{line}",
          "last status:  #{status}",
          "run reason:   #{meta['run_reason'] || '<not recorded>'}"
        ]
      end

      def self.first_non_nil(meta, *keys)
        keys.each { |k| return meta[k] unless meta[k].nil? }
        nil
      end

      def self.print_dependency_summary(stdout, meta, run_dir)
        deps_path = File.join(run_dir, 'dependency.json')
        return unless File.file?(deps_path)

        deps = read_json(deps_path)
        id = meta['example_id'] || meta['id']
        files = Array(deps[id])
        stdout.puts "dependencies: #{files.size} files tracked"
        files.first(10).each { |f| stdout.puts "  - #{f}" }
        stdout.puts "  ... (#{files.size - 10} more)" if files.size > 10
      end
    end
  end
end
