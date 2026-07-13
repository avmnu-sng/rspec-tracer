# frozen_string_literal: true

require 'spec_helper'
require 'bundler'
require 'fileutils'
require 'open3'
require 'tmpdir'

# Real-user-shape integration coverage for sqlite cache persistence
# on FAILING runs. A suite that ends red exits through RSpec's
# `Kernel.exit(1)`, so the tracer's at_exit persist runs with a
# SystemExit pending in rb_errinfo. sqlite3's Statement#step used to
# re-surface that pending exit on the first stepped statement, which
# silently aborted the persist: a fresh cache dir was left with a
# zero-byte rspec_tracer.sqlite3 and the next run logged "not a
# valid SQLite database" and started cold. The cache never warmed
# for any project with a failing example.
#
# Assertions follow the cache-persistence discipline used across
# spec/integration: assert on the on-disk cache state AND the next
# run's filter decision (the re-run set), never on exit status alone.
#
# SqliteBackend is MRI-only; skip when the sqlite3 gem is absent
# (JRuby matrix cells).
return unless RUBY_ENGINE == 'ruby'

begin
  require 'sqlite3'
rescue LoadError
  return
end

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe 'sqlite cache persistence on failing runs integration' do
  let(:project_root) { File.expand_path('../..', __dir__) }
  let(:gemfile_path) { File.join(project_root, 'Gemfile') }

  # SQLite's on-disk format opens with these 16 magic bytes; a file
  # that lacks them (e.g. the zero-byte husk the bug left behind) is
  # not a database.
  let(:sqlite_magic) { "SQLite format 3\x00".b }

  # The passing example must exercise an app file: the warm-run skip
  # decision needs a dependency row proving its inputs are unchanged.
  # A dependency-free example re-runs every time with reason
  # "No cache" and would mask the warmness assertion below.
  def write_fixture_config(dir)
    File.write(File.join(dir, '.rspec-tracer'), <<~RUBY)
      # frozen_string_literal: true
      RSpecTracer.configure do
        storage_backend :sqlite
      end
    RUBY
    File.write(File.join(dir, 'adder.rb'), <<~RUBY)
      class Adder
        def self.add(a, b)
          a + b
        end
      end
    RUBY
  end

  def write_fixture(dir)
    write_fixture_config(dir)
    File.write(File.join(dir, 'spec_helper.rb'), <<~RUBY)
      require 'rspec_tracer'
      RSpecTracer.start
      require_relative 'adder'
    RUBY
    File.write(File.join(dir, 'failing_suite_spec.rb'), <<~RUBY)
      require_relative 'spec_helper'

      RSpec.describe 'suite with a red example' do
        it 'passes' do
          expect(Adder.add(1, 1)).to eq(2)
        end

        it 'fails deliberately' do
          expect(Adder.add(1, 0)).to eq(2)
        end
      end
    RUBY
  end

  def run_rspec(dir)
    Bundler.with_unbundled_env do
      env = {
        'BUNDLE_GEMFILE' => gemfile_path,
        'GIT_DEFAULT_BRANCH' => nil,
        'GIT_BRANCH' => nil,
        'RSPEC_TRACER_STORAGE' => nil
      }
      out, status = Open3.capture2e(env, 'bundle', 'exec', 'rspec', '--no-color',
                                    'failing_suite_spec.rb', chdir: dir)
      # The tracer summary line contains UTF-8 punctuation; Open3
      # tags output with the parent's default_external, which is
      # US-ASCII in some CI shells and breaks regex matching.
      [out.force_encoding(Encoding::UTF_8).scrub, status]
    end
  end

  def db_path(dir)
    File.join(dir, 'rspec_tracer_cache', 'rspec_tracer.sqlite3')
  end

  def meta_timestamp(dir)
    db = SQLite3::Database.new(db_path(dir))
    db.get_first_row('SELECT timestamp FROM meta LIMIT 1')&.first
  ensure
    db&.close
  end

  it 'persists a valid database on a red run and the next red run is warm, not cold' do
    Dir.mktmpdir do |dir|
      write_fixture(dir)

      first_out, first_status = run_rspec(dir)

      expect(first_status.exitstatus).to eq(1), "expected red exit, got:\n#{first_out}"
      expect(File.file?(db_path(dir))).to be(true), "no sqlite cache written:\n#{first_out}"
      expect(File.size(db_path(dir))).to be > 0
      expect(File.binread(db_path(dir), sqlite_magic.bytesize)).to eq(sqlite_magic)
      first_timestamp = meta_timestamp(dir)
      expect(first_timestamp).not_to be_nil

      sleep 1 # meta timestamps have second granularity
      second_out, second_status = run_rspec(dir)

      expect(second_status.exitstatus).to eq(1)
      expect(second_out).not_to include('not a valid SQLite database')
      # The warm-run filter decision: only the failing example re-runs,
      # the passing one is served from cache.
      expect(second_out).to include(
        'RSpec tracer is running 1 examples (actual: 2, skipped: 1)'
      ), "expected a warm second run (1 re-run, 1 skipped), got:\n#{second_out}"
      # The at_exit finalize must complete on a red run: the summary
      # line only prints after the persist, and the meta timestamp
      # only advances when save_graph committed. A silently-skipped
      # finalize (the pre-fix behavior on warm red runs) passes the
      # banner assertion above but fails both of these.
      expect(second_out).to include('rspec-tracer: 2 examples tracked'),
                            "at_exit summary missing (finalize silently skipped?):\n#{second_out}"
      expect(meta_timestamp(dir)).not_to eq(first_timestamp)
      expect(File.binread(db_path(dir), sqlite_magic.bytesize)).to eq(sqlite_magic)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
