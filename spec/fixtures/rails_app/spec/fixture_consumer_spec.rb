# frozen_string_literal: true

require 'rails_helper'

# Anchor spec for the behavior-matrix row
# "spec/fixtures/users.yml → only fixture-using examples." The fixture's
# other specs rely on FactoryBot rather than AR fixtures, so without
# this spec no example would have users.yml in its dependency set and
# the scenario would be untestable end-to-end. Loading the YAML via
# Psych fires the IOHooks YAML interception, which attributes the file
# as a :data Input on this example.
RSpec.describe 'spec/fixtures/users.yml consumer' do
  let(:fixture_path) { Rails.root.join('spec/fixtures/users.yml') }

  it 'loads the YAML and exposes the seed_admin fixture' do
    data = YAML.load_file(fixture_path)

    expect(data).to include('seed_admin')
    expect(data.fetch('seed_admin')).to include('name')
  end
end
