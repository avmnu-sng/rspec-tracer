# frozen_string_literal: true

# Pre-loaded into the soak subprocess via RUBYOPT="-r<this-file>".
# Starts RSpecTracer before the project's spec_helper / rails_helper
# runs, so Coverage interception sees the project's source files
# from the very first require.
#
# Universal hook: avoids having to patch each external project's
# spec_helper.rb / rails_helper.rb to insert RSpecTracer.start at
# the right point. The soak fixture task only injects the gem into
# the project's Gemfile; this file does the runtime activation.
#
# Bundler.setup must run before requiring rspec_tracer because
# `bundle exec` appends `-rbundler/setup` to RUBYOPT *after* our
# `-r<this-file>`. At RUBYOPT processing time the bundle isn't yet
# activated and `require 'rspec_tracer'` would miss the gem path.
# Calling Bundler.setup explicitly here activates BUNDLE_GEMFILE's
# resolved gem set; the subsequent bundle/setup load (from bundler/
# setup added by bundle exec) is a no-op (Bundler.setup is
# idempotent).
#
# Graceful-degradation: if the require fails (fixture Gemfile didn't
# resolve rspec-tracer or Bundler.setup raises), warn to stderr and
# continue. The parent spec's verify_cache_state catches the
# missing-cache failure mode anyway - tracer-not-loaded surfaces
# there as "rspec_tracer_cache/ missing" rather than crashing this
# preload.

begin
  require 'bundler/setup'
  require 'rspec_tracer'
  RSpecTracer.start
rescue LoadError, Bundler::BundlerError => e
  warn "soak_start: failed to start rspec_tracer (#{e.class}: #{e.message})"
end
