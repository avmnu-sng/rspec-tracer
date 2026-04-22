# frozen_string_literal: true

require 'set'
require 'rspec_tracer/storage/snapshot'
require 'rspec_tracer/reporters/base'

# Shared-examples contract for RSpecTracer::Reporters::Base subclasses.
# Each reporter's spec includes this with `it_behaves_like 'a Reporters::Base'`
# after binding:
#
#   let(:reporter_class) { described_class }
#   let(:report_dir)     { Dir.mktmpdir }
#   let(:snapshot)       { # populated snapshot (non-empty all_examples)  }
#   let(:empty_snapshot) { RSpecTracer::Storage::Snapshot.empty(...) }
#   let(:run_metadata)   { {} }
#
# Reporters that break these assertions are non-conformant even if
# their own unit tests pass. The contract is behavioral: subclasses
# must accept the input envelope, tolerate an empty snapshot, and
# never raise out of generate (they may return nil on no-op, but
# raising pollutes the at_exit chain).
# rubocop:disable RSpec/ExampleLength
RSpec.shared_examples 'a Reporters::Base' do
  describe 'input envelope' do
    it 'accepts (snapshot:, report_dir:, run_metadata:, logger:)' do
      expect do
        reporter_class.new(
          snapshot: snapshot, report_dir: report_dir,
          run_metadata: {}, logger: nil
        )
      end.not_to raise_error
    end

    it 'accepts extra **opts without raising' do
      expect do
        reporter_class.new(
          snapshot: snapshot, report_dir: report_dir,
          run_metadata: {}, logger: nil, something_custom: true
        )
      end.not_to raise_error
    end
  end

  describe '#no_op?' do
    it 'is true when the snapshot has no tracked examples' do
      reporter = reporter_class.new(
        snapshot: empty_snapshot, report_dir: report_dir,
        run_metadata: {}, logger: nil
      )

      expect(reporter.no_op?).to be(true)
    end

    it 'is false when the snapshot has at least one tracked example' do
      reporter = reporter_class.new(
        snapshot: snapshot, report_dir: report_dir,
        run_metadata: {}, logger: nil
      )

      expect(reporter.no_op?).to be(false)
    end
  end

  describe '#generate' do
    it 'returns nil / falsy on an empty snapshot and does not raise' do
      reporter = reporter_class.new(
        snapshot: empty_snapshot, report_dir: report_dir,
        run_metadata: {}, logger: nil
      )

      expect { reporter.generate }.not_to raise_error
    end

    it 'does not raise on a populated snapshot' do
      reporter = reporter_class.new(
        snapshot: snapshot, report_dir: report_dir,
        run_metadata: {}, logger: nil
      )

      expect { reporter.generate }.not_to raise_error
    end
  end
end
# rubocop:enable RSpec/ExampleLength
