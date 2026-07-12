# frozen_string_literal: true

require "rails_helper"

# Wide-AR-schema fixture spec. Three AR-touching examples + one
# pure-compute example designed to exercise the SAFE-BUT-WIDE schema
# attribution under common Rails AR-cleanup setups (transactional
# fixtures = true OR DatabaseCleaner :truncation / :deletion /
# :transaction in around hooks).
#
# The OUTER spec/integration/wide_ar_schema_*_spec.rb suite drives this
# fixture once per scenario, then asserts:
#   1. db/schema.rb is in the dependency set of every AR-touching
#      example (NOT only the schema-mutator example - the per-example
#      cleanup mechanism contaminates attribution).
#   2. Schema mutation re-runs every AR-touching example.
#   3. The pure-compute example - which opts out of both transactional
#      fixtures AND the DatabaseCleaner around hook - is NOT re-run on
#      schema mutation, demonstrating the widening boundary: only
#      examples whose lifecycle fires `sql.active_record` get schema
#      attributed.
#
# Real users typically apply transactional fixtures or DBC universally
# (no per-describe opt-out), and so see widening across every example
# in the suite. This fixture documents the boundary precisely by
# demonstrating where it stops.
RSpec.describe "wide AR schema attribution" do
  describe "AR-touching examples", :db_cleaned, type: :model do
    it "creates user A" do
      user = User.create!(
        name: "wide-A",
        email: "wide-a-#{Time.now.to_f}-#{Process.pid}@example.com"
      )
      expect(user).to be_persisted
    end

    it "creates user B" do
      user = User.create!(
        name: "wide-B",
        email: "wide-b-#{Time.now.to_f}-#{Process.pid}@example.com"
      )
      expect(user).to be_persisted
    end

    it "creates user C and counts" do
      User.create!(
        name: "wide-C",
        email: "wide-c-#{Time.now.to_f}-#{Process.pid}@example.com"
      )
      expect(User.count).to be >= 1
    end
  end

  describe "pure-compute (no AR setup)", type: :model do
    # Per-describe opt-out from transactional fixtures via the
    # ActiveRecord::TestFixtures class-method setter (Rails 5+ name).
    # Combined with the absence of `:db_cleaned` metadata (so the
    # rails_helper `config.around(:each, :db_cleaned)` skips this
    # describe), no `sql.active_record` event fires for these examples
    # - their bucket is empty of AR events, so db/schema.rb never
    # enters the dependency set.
    self.use_transactional_tests = false

    it "performs only pure-Ruby computation" do
      expect(2 + 2).to eq(4)
    end
  end
end
