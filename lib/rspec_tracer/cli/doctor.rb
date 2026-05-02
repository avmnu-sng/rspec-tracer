# frozen_string_literal: true

module RSpecTracer
  module CLI
    # `rspec-tracer doctor` — diagnose config + environment.
    # Reports Ruby + rspec-tracer versions, project root resolution,
    # cache / coverage / report directory state, and SimpleCov / Rails
    # presence. Exits 0 on healthy diagnosis, 1 if any check fails.
    module Doctor
      def self.run(args, stdout: $stdout, stderr: $stderr)
        return print_help(stdout) if args.include?('-h') || args.include?('--help')

        require 'rspec_tracer/load_config'

        checks = [
          ruby_version_check,
          tracer_version_check,
          project_root_check,
          cache_path_check,
          coverage_path_check,
          report_path_check,
          git_check,
          simplecov_check,
          rails_check
        ]
        checks.each { |line| stdout.puts line }
        ok = checks.none? { |line| line.start_with?('FAIL') }
        ok ? 0 : 1
      rescue StandardError => e
        stderr.puts "doctor: #{e.class}: #{e.message}"
        1
      end

      def self.print_help(stdout)
        stdout.puts <<~HELP
          Usage: rspec-tracer doctor

          Diagnose rspec-tracer config and environment. Prints a checklist
          of versions, paths, and integrations; exits 0 if all checks pass.
        HELP
        0
      end

      def self.ruby_version_check
        "OK   ruby:        #{RUBY_DESCRIPTION}"
      end

      def self.tracer_version_check
        "OK   rspec-tracer: #{RSpecTracer::VERSION}"
      end

      def self.project_root_check
        "OK   root:        #{RSpecTracer.root}"
      end

      def self.cache_path_check
        path_check('cache_path:', RSpecTracer.cache_path)
      end

      def self.coverage_path_check
        path_check('coverage_path:', RSpecTracer.coverage_path)
      end

      def self.report_path_check
        path_check('report_path:', RSpecTracer.report_path)
      end

      def self.path_check(label, path)
        return "FAIL #{label} <missing>" if path.nil? || path.empty?
        return "FAIL #{label} #{path} (does not exist)" unless File.directory?(path)
        return "FAIL #{label} #{path} (not writable)" unless File.writable?(path)

        "OK   #{label} #{path}"
      end

      def self.git_check
        if system('git', 'rev-parse', 'HEAD', out: File::NULL, err: File::NULL)
          'OK   git:         HEAD reachable (remote_cache will work)'
        else
          'WARN git:         not in a git repo (remote_cache will degrade gracefully)'
        end
      end

      def self.simplecov_check
        if defined?(::SimpleCov)
          'OK   SimpleCov:   loaded (interop active)'
        else
          'INFO SimpleCov:   not loaded (this is fine; SimpleCov is optional)'
        end
      end

      def self.rails_check
        if defined?(::Rails::VERSION) && !::Rails::VERSION.nil?
          "OK   Rails:       #{::Rails::VERSION::STRING}"
        else
          'INFO Rails:       not loaded (this is fine for non-Rails projects)'
        end
      end
    end
  end
end
