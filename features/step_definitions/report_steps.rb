# frozen_string_literal: true

Then('The RSpecTracer should print the information') do |expected_output|
  output = last_command_started.output.lines
    .map(&:strip)
    .reject(&:empty?)
    .map { |line| line.gsub(/\e\[\d+m/, '') }

  expected = expected_output.lines.map(&:strip).reject(&:empty?)

  expect(output & expected).to contain_exactly(*expected)
end

Then('The RSpecTracer report should have been generated') do
  steps %(
    Then a directory named "#{@cache_dir}" should exist
    And the following files should exist:
      | #{@cache_dir}/last_run.json                       |
      | #{@cache_dir}/#{@run_id}/all_examples.json        |
      | #{@cache_dir}/#{@run_id}/all_files.json           |
      | #{@cache_dir}/#{@run_id}/dependency.json          |
      | #{@cache_dir}/#{@run_id}/examples_coverage.json   |
      | #{@cache_dir}/#{@run_id}/failed_examples.json     |
      | #{@cache_dir}/#{@run_id}/pending_examples.json    |
      | #{@cache_dir}/#{@run_id}/reverse_dependency.json  |
  )
end

Then('The last run report should have correct details') do |report_json|
  cd('.') do
    report = JSON.parse(File.read("#{@cache_dir}/last_run.json"))
    attrs = %w[run_id actual_count example_count skipped_examples failed_examples pending_examples]
    report = report.slice(*attrs)

    expect(report).to eq(JSON.parse(report_json))
  end
end

Then('The all examples report should have correct details') do
  project_dir = File.dirname(__FILE__)
  data_file = File.join(project_dir, "../#{@data_dir}/all_examples.json")
  data = JSON.parse(File.read(data_file))

  cd('.') do
    report = JSON.parse(File.read("#{@cache_dir}/#{@run_id}/all_examples.json"))

    expect(report.keys.sort).to eq(data.keys.sort)

    report.each_pair do |example_id, example|
      expect(example).to include(data[example_id])
    end
  end
end

Then('The all files report should have correct details') do |table|
  data = table.hashes.map { |a| [a['file_name'], a['file_digest']] }.to_h

  cd('.') do
    report = JSON.parse(File.read("#{@cache_dir}/#{@run_id}/all_files.json"))

    expect(report.keys.sort).to eq(data.keys.sort)

    report.each_pair do |file_name, file_data|
      expect(file_data['digest']).to eq(data[file_name])
    end
  end
end

Then('The failed example report should have correct details') do
  cd('.') do
    report = JSON.parse(File.read("#{@cache_dir}/#{@run_id}/failed_examples.json"))
    example = case @project
              when 'rails_app'
                ['338f77315d8f7c01ea5551cd0759b110']
              when 'ruby_app'
                ['b5963ecab8d95c1024a46117fce4e907']
              end

    expect(report).to eq(example)
  end
end

Then('The pending example report should have correct details') do
  cd('.') do
    report = JSON.parse(File.read("#{@cache_dir}/#{@run_id}/pending_examples.json"))

    expect(report).to eq(['94cd4d0e1d9ef63237421fe02085eb9a'])
  end
end

Then('The dependency report should have correct details') do
  project_dir = File.dirname(__FILE__)
  data_file = File.join(project_dir, "../#{@data_dir}/dependency.json")
  data = JSON.parse(File.read(data_file))

  cd('.') do
    report = JSON.parse(File.read("#{@cache_dir}/#{@run_id}/dependency.json"))

    expect(report.keys.sort).to eq(data.keys.sort)

    report.each_pair do |example_id, dependency|
      expect(dependency).to contain_exactly(*data[example_id])
    end
  end
end

Then('The reverse dependency report should have correct details') do
  project_dir = File.dirname(__FILE__)
  data_file = File.join(project_dir, "../#{@data_dir}/reverse_dependency.json")
  data = JSON.parse(File.read(data_file))

  cd('.') do
    report = JSON.parse(File.read("#{@cache_dir}/#{@run_id}/reverse_dependency.json"))

    expect(report.keys.sort).to eq(data.keys.sort)

    report.each_pair do |example_id, dependency|
      expect(dependency).to eq(data[example_id])
    end
  end
end
