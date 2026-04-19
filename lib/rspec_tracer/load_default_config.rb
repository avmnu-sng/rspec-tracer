# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength
RSpecTracer.configure do
  log_level :info
  fail_on_duplicates true

  filters.clear
  add_filter %w[
    /vendor/bundle/
    /lib/rspec_tracer/
    /lib/rspec_tracer.rb
    /usr/local/lib/ruby/
    /usr/local/bundle/
    /opt/hostedtoolcache/
    /.rbenv/versions/
    /.asdf/installs/ruby/
    /.rvm/
  ].freeze

  coverage_filters.clear
  add_coverage_filter %w[
    /autotest/
    /features/
    /spec/
    /test/
    /vendor/bundle/
    /lib/rspec_tracer/
    /lib/rspec_tracer.rb
    /usr/local/lib/ruby/
    /usr/local/bundle/
    /opt/hostedtoolcache/
    /.rbenv/versions/
    /.asdf/installs/ruby/
    /.rvm/
  ].freeze
end
# rubocop:enable Metrics/BlockLength
