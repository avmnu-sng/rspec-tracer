# frozen_string_literal: true

Then('The JSON coverage report should have been generated for {string}') do |type|
  next if ENV.fetch('SKIP_COVERAGE_VALIDATION', 'false') == 'true'

  @coverage_type = type

  if type == 'ParallelTestsRSpec'
    require 'parallel'

    processor_count = Parallel.processor_count
    @coverage_type = "(1/#{processor_count}), (2/#{processor_count})"
  end

  steps %(
    Then the output should contain "Coverage report generated for #{@coverage_type}"
  )

  if type == 'RSpecTracer'
    steps %(
      And a directory named "#{@coverage_dir}" should exist
      And the following files should exist:
        | #{@coverage_dir}/coverage.json |
    )
  else
    steps %(
      And a directory named "coverage" should exist
      And the following files should exist:
        | coverage/.resultset.json |
        | coverage/index.html      |
    )
  end
end

# rubocop:disable Metrics/BlockLength
Then('The JSON coverage report should have correct coverage for {string}') do |_type|
  next if ENV.fetch('SKIP_COVERAGE_VALIDATION', 'false') == 'true'

  project_dir = File.dirname(__FILE__)
  data_file = File.join(project_dir, "../#{@data_dir}/coverage.json")
  data = JSON.parse(File.read(data_file))

  coverage_file = if @coverage_type == 'RSpecTracer'
                    "#{@coverage_dir}/coverage.json"
                  else
                    'coverage/.resultset.json'
                  end

  cd('.') do
    root_dir = Dir.pwd
    report = {}

    @coverage_type.split(', ').each do |sub_type|
      report.merge!(JSON.parse(File.read(coverage_file))[sub_type]['coverage'])
    end

    expected_files = data.keys.sort

    if @coverage_type != 'RSpecTracer'
      expected_files -= %w[
        app/foo.rb
        app/controllers/application_controller.rb
        app/jobs/application_job.rb
        app/models/application_record.rb
        app/models/foo.rb
      ]
    end

    expect(report.keys.sort).to eq(
      expected_files.map { |expected_file_name| "#{root_dir}/#{expected_file_name}" }
    )

    report.each_pair do |file_name, coverage_data|
      next unless expected_files.include?(file_name)

      if coverage_data.is_a?(Hash)
        expect(coverage_data['lines']).to eq(data[file_name])
      else
        expect(coverage_data).to eq(data[file_name])
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength

Then('The coverage percent stat is {string}') do |coverage_stat|
  next if ENV.fetch('SKIP_COVERAGE_VALIDATION', 'false') == 'true'

  expect(last_command_started.output).to include(coverage_stat)
end
