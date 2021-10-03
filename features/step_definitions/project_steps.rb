# frozen_string_literal: true

Given('I am working on the project {string}') do |project|
  @project = project
  @cache_dir = 'rspec_tracer_cache'
  @coverage_dir = 'rspec_tracer_coverage'
  @data_dir = "data/#{@project}"
  @run_id = {
    rails_app: '6654a84c672a717904112cef7503d7a1',
    ruby_app: '63df6c782675a201fbef23140bd868e2',
    calculator_app: 'ac50ff82ef0e8c97f7142ae07483d81d',
    calculator_2_app: '35194a37e68446e9d6960c46e717fd44',
    calculator_3_app: 'ac50ff82ef0e8c97f7142ae07483d81d'
  }[@project.to_sym]

  project_dir = File.dirname(__FILE__)

  cd('.') do
    FileUtils.rm_rf('project')

    FileUtils.cp_r(
      File.join(project_dir, "../../sample_projects/#{project}/"),
      'project'
    )

    FileUtils.mkdir_p('/tmp/helpers')
    FileUtils.touch('/tmp/helpers/test.rb')
  end
end

Given('I use {string} as spec helper') do |spec_helper|
  project_dir = File.dirname(__FILE__)

  cd('.') do
    FileUtils.cp(
      File.join(project_dir, "../../sample_projects/spec_helpers/#{@project}/#{spec_helper}"),
      'project/spec/spec_helper.rb'
    )
  end

  steps %(
    When I cd to "project"
  )
end

Given('I replace spec helper with {string}') do |spec_helper|
  project_dir = File.dirname(__FILE__)

  cd('.') do
    FileUtils.cp(
      File.join(project_dir, "../../sample_projects/spec_helpers/#{@project}/#{spec_helper}"),
      'spec/spec_helper.rb'
    )
  end
end

Given('I update the spec file {string}') do |spec_file|
  project_dir = File.dirname(__FILE__)

  cd('.') do
    FileUtils.cp(
      File.join(project_dir, "../../sample_projects/updated_files/#{@project}/spec/#{spec_file}.rb"),
      "spec/#{spec_file}.rb"
    )
  end
end

Given('I want to explicitly run all the tests') do
  set_environment_variable('RSPEC_TRACER_NO_SKIP', 'true')
end

Given('I reset explicit run') do
  delete_environment_variable('RSPEC_TRACER_NO_SKIP')
end

Given('I want to force fail some of the tests') do
  set_environment_variable('FORCE_FAIL', 'true')

  @force_fail = true
  @data_dir = "data/#{@project}/force_fail"
end

Given('I reset force fail') do
  delete_environment_variable('FORCE_FAIL')

  @force_fail = false
  @data_dir = "data/#{@project}"
end

Given('I use test suite id {int}') do |suite_id|
  @suite_id = suite_id
  @cache_dir = "rspec_tracer_cache/#{@suite_id}"
  @coverage_dir = "rspec_tracer_coverage/#{@suite_id}"
  @data_dir = "data/#{@project}/#{@suite_id}"
  @run_id = case [@project, @suite_id]
            when ['ruby_app', 1]
              '9badef37e6a3dd45e4d0342956371b73'
            when ['rails_app', 1]
              'cf7e97dcafe77149bac34e2f6f35ff38'
            when ['ruby_app', 2]
              '2c48486d4513ef0eeee4e7ab8c284419'
            when ['rails_app', 2]
              'aa2c6f193206bf829ea3cb17f5c7672e'
            end

  set_environment_variable('TEST_SUITE_ID', suite_id)
end

Given('I reset test suite id') do
  @suite_id = nil
  @cache_dir = 'rspec_tracer_cache'
  @coverage_dir = 'rspec_tracer_coverage'
  @data_dir = "data/#{@project}"
  @run_id = case @project
            when 'rails_app'
              '6654a84c672a717904112cef7503d7a1'
            when 'ruby_app'
              '63df6c782675a201fbef23140bd868e2'
            end

  delete_environment_variable('TEST_SUITE_ID')
end

When('I run specs using {string}') do |command|
  steps %(
    When I successfully run `bundle install --jobs 3 --retry 3` for up to 120 seconds
    Then I validate simplecov version
    And I validate rspec or rspec rails version
    And I run `bundle exec #{command}`
  )
end

Then('I validate simplecov version') do
  cd('.') do
    expected = Gem::Dependency.new('simplecov', ENV['SIMPLECOV_VERSION'])
    actual = Gem::Dependency.new(
      'simplecov',
      `bundle show simplecov`.chomp.split("\n").first.split('/').last.split('-').last
    )

    expect(expected =~ actual).to eq(true)
  end
end

Then('I validate rspec or rspec rails version') do
  cd('.') do
    case @project
    when 'rails_app'
      rspec_gem = 'rspec-rails'
      expected = Gem::Dependency.new(rspec_gem, ENV['RSPEC_RAILS_VERSION'])
    when 'ruby_app', 'calculator_app', 'calculator_2_app', 'calculator_3_app'
      rspec_gem = 'rspec'
      expected = Gem::Dependency.new(rspec_gem, ENV['RSPEC_VERSION'])
    end

    actual = Gem::Dependency.new(
      rspec_gem,
      `bundle show #{rspec_gem}`.chomp.split("\n").first.split('/').last.split('-').last
    )

    expect(expected =~ actual).to eq(true)
  end
end
