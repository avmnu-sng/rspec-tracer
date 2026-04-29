# frozen_string_literal: true

require "rails_helper"

# M8.2-B narrow-AR-schema fixture spec. Two examples:
#   - one issues an AR query (User.create!) so the sql.active_record
#     subscriber fires and rspec-tracer's record_ar_schema attributes
#     `db/schema.rb` to this example_id;
#   - one performs only a pure-Ruby computation, so the subscriber
#     never fires and `db/schema.rb` is NOT in this example_id's
#     dependency set.
#
# The OUTER `spec/integration/narrow_ar_schema_spec.rb` drives this
# fixture with `RSPEC_TRACER_RAILS_TRANSACTIONAL=false`, asserts the
# per-example attribution above, mutates `db/schema.rb`, and verifies
# the warm filter re-runs only the AR-touching example.
RSpec.describe "narrow AR schema attribution" do
  it "creates a user (touches AR)" do
    # Time-suffixed email so re-runs under non-transactional fixtures
    # don't collide on the email uniqueness index even without
    # DatabaseCleaner. (DatabaseCleaner was tried in M8.2-B and rejected:
    # its TRUNCATE / DELETE queries fire inside the per-example bucket,
    # which then attributes db/schema.rb to *every* example via the
    # sql.active_record subscriber - completely defeating the test of
    # narrow AR-schema attribution. Sequence-based uniqueness is the
    # only setup that lets us assert the pure example genuinely does
    # not depend on the schema.)
    user = User.create!(
      name: "Narrow AR test",
      email: "narrow-#{Time.now.to_f}-#{Process.pid}@example.com"
    )
    expect(user).to be_persisted
  end

  it "computes a pure value (does not touch AR)" do
    expect(2 + 2).to eq(4)
  end
end
