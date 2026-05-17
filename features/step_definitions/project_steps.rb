# frozen_string_literal: true

Given('I am working on the project {string}') do |project|
  @project = project
  @cache_dir = 'rspec_tracer_cache'
  @coverage_dir = 'rspec_tracer_coverage'
  @data_dir = "data/#{@project}"
  @run_id = {
    parallel_tests_ruby_app: '140cef8616cc1ad1a42b3cfd0995af1b',
    parallel_tests_ruby_app_many_spec_files: 'dda6cd4ac89b153240d50f39a191e1b3',
    rails_app: '140cef8616cc1ad1a42b3cfd0995af1b',
    ruby_app: '140cef8616cc1ad1a42b3cfd0995af1b',
    calculator_app: '74fc3ff84ae8c0ad6f457c7bfc48283c',
    calculator_2_app: '02b2f83e3b17ffc59ad4194252d8dedb',
    calculator_3_app: '74fc3ff84ae8c0ad6f457c7bfc48283c'
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
  set_environment_variable('RSPEC_TRACER_RUN_ALL_EXAMPLES', 'true')
end

Given('I reset explicit run') do
  delete_environment_variable('RSPEC_TRACER_RUN_ALL_EXAMPLES')
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

Given('I want to ignore duplicate examples failures') do
  set_environment_variable('RSPEC_TRACER_FAIL_ON_DUPLICATES', 'false')
end

Given('I reset ignore duplicate examples failures') do
  delete_environment_variable('RSPEC_TRACER_FAIL_ON_DUPLICATES')
end

Given('I use test suite id {int}') do |suite_id|
  @suite_id = suite_id
  @cache_dir = "rspec_tracer_cache/#{@suite_id}"
  @coverage_dir = "rspec_tracer_coverage/#{@suite_id}"
  @data_dir = "data/#{@project}/#{@suite_id}"
  @run_id = case [@project, @suite_id]
            when ['parallel_tests_ruby_app', 1], ['ruby_app', 1], ['rails_app', 1]
              '49d3367ed4d78b8879fbc36573bc7695'
            when ['parallel_tests_ruby_app', 2], ['ruby_app', 2], ['rails_app', 2]
              '574ae20ab240013a0bce29ac35957849'
            end

  set_environment_variable('TEST_SUITE_ID', suite_id)
end

Given('I reset test suite id') do
  @suite_id = nil
  @cache_dir = 'rspec_tracer_cache'
  @coverage_dir = 'rspec_tracer_coverage'
  @data_dir = "data/#{@project}"
  @run_id = case @project
            when 'rails_app', 'parallel_tests_ruby_app', 'ruby_app'
              '140cef8616cc1ad1a42b3cfd0995af1b'
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
    expected = Gem::Dependency.new('simplecov', ENV.fetch('SIMPLECOV_VERSION', nil))
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
      expected = Gem::Dependency.new(rspec_gem, ENV.fetch('RSPEC_RAILS_VERSION', nil))
    when 'parallel_tests_ruby_app',
         'parallel_tests_ruby_app_many_spec_files',
         'ruby_app',
         'calculator_app',
         'calculator_2_app',
         'calculator_3_app'
      rspec_gem = 'rspec'
      expected = Gem::Dependency.new(rspec_gem, ENV.fetch('RSPEC_VERSION', nil))
    end

    actual = Gem::Dependency.new(
      rspec_gem,
      `bundle show #{rspec_gem}`.chomp.split("\n").first.split('/').last.split('-').last
    )

    expect(expected =~ actual).to eq(true)
  end
end
