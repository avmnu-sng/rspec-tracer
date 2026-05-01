# frozen_string_literal: true

# Regression spec for the symptom originally reported in
# https://github.com/avmnu-sng/rspec-tracer/issues/66 — Rails users
# observed that modifying ERB / Slim / JBuilder templates did NOT
# invalidate the specs that rendered them, leading to stale-cache
# false-greens. The 1.x architecture was Coverage-only, which doesn't
# observe template renders; the only workaround in 1.x was to clear
# `rspec_tracer_cache/*` manually before each run.
#
# The 2.0 architecture closes the gap via the
# `render_template.action_view` ActiveSupport::Notifications
# subscriber (lib/rspec_tracer/rails/notifications.rb #record_template).
# When a controller spec renders a template, the subscriber fires +
# emits a `:template`-kind Input attributing the rendered file to
# that example's bucket. A subsequent edit of the template
# invalidates exactly the examples that rendered it.
#
# This spec drives the rails_app fixture cold + warm with a single
# template mutation and asserts:
#
#   1. The rendered template appears in `reverse_dependency.json`
#      under the controller-spec example IDs (the subscriber wired
#      it correctly).
#   2. The warm filter, post-mutation, re-runs exactly the
#      example IDs that depend on the mutated template - no more,
#      no fewer.
#
# The fixture's `.rspec-tracer` opts out of the `:views` declared
# glob (`track_rails_defaults except: [:views, :schema]`), so the
# subscriber path is the ONLY mechanism observing template changes -
# matching the real-user fix path the 2.0 architecture provides.

require 'bundler'
require 'open3'
require 'set'

require_relative '../support/fixture_bundle_helper'

module TemplateChangeInvalidatesDependentsSpecHelpers
  TRACER_ENV = { 'RSPEC_TRACER' => '1' }.freeze
  SUBPROCESS_BUNDLE_ENV = { 'BUNDLE_FROZEN' => '1' }.freeze
  TEMPLATE_PATH = 'app/views/users/show.html.erb'
  TEMPLATE_CACHE_KEY = '/app/views/users/show.html.erb'
  MUTATION_MARKER = "\n<!-- rspec-tracer regression #66 mutation marker -->\n"

  module_function

  def run_rspec_in_fixture
    Bundler.with_unbundled_env do
      Open3.capture2e(TRACER_ENV.merge(SUBPROCESS_BUNDLE_ENV),
                      'bundle', 'exec', 'rspec', '--no-color',
                      chdir: FixtureBundleHelper::FIXTURE_ROOT)
    end
  end
end

# rubocop:disable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/InstanceVariable, RSpec/ExampleLength
RSpec.describe 'template change invalidates dependent examples (regression for upstream #66)' do
  include TemplateChangeInvalidatesDependentsSpecHelpers

  before(:all) do
    FixtureBundleHelper.ensure_bundle_and_db
    FixtureBundleHelper.clear_tracer_state

    out, status = TemplateChangeInvalidatesDependentsSpecHelpers.run_rspec_in_fixture
    raise "cold rspec failed (status=#{status.exitstatus}):\n#{out}" unless status.success?

    @cold_all_examples = FixtureBundleHelper.load_cache_file('all_examples.json')
    @cold_reverse_dependency = FixtureBundleHelper.load_cache_file('reverse_dependency.json')
    @template_renderers = @cold_reverse_dependency
      .fetch(TemplateChangeInvalidatesDependentsSpecHelpers::TEMPLATE_CACHE_KEY, [])
      .to_set
  end

  after(:all) do
    FixtureBundleHelper.clear_tracer_state
  end

  describe 'cold attribution via render_template.action_view subscriber' do
    it 'attributes the rendered template to the example IDs that rendered it' do
      expect(@template_renderers).not_to(be_empty,
                                         'expected at least one example to depend on the rendered template; ' \
                                         'subscriber may not have fired or the path normalization is off')
    end
  end

  describe 'warm filter after template mutation' do
    it 're-runs exactly the examples that depend on the mutated template' do
      template_path = File.join(FixtureBundleHelper::FIXTURE_ROOT,
                                TemplateChangeInvalidatesDependentsSpecHelpers::TEMPLATE_PATH)
      original = File.binread(template_path)
      File.open(template_path, 'ab') do |f|
        f.write(TemplateChangeInvalidatesDependentsSpecHelpers::MUTATION_MARKER)
      end

      begin
        out, status = TemplateChangeInvalidatesDependentsSpecHelpers.run_rspec_in_fixture
        raise "warm rspec failed (status=#{status.exitstatus}):\n#{out}" unless status.success?

        all_example_ids = @cold_all_examples.keys.to_set
        skipped = FixtureBundleHelper.load_cache_file('skipped_examples.json').to_set
        re_run = all_example_ids - skipped

        expect(re_run).to(eq(@template_renderers),
                          'warm re-run set did not match the template renderers exactly: ' \
                          "missing from re-run: #{(@template_renderers - re_run).to_a.inspect}; " \
                          "unexpected in re-run: #{(re_run - @template_renderers).to_a.inspect}")
      ensure
        File.binwrite(template_path, original)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/InstanceVariable, RSpec/ExampleLength
