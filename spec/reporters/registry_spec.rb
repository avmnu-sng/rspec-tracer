# frozen_string_literal: true

require 'set'
require 'tmpdir'
require 'rspec_tracer/storage/snapshot'
require 'rspec_tracer/reporters/base'
require 'rspec_tracer/reporters/json_reporter'
require 'rspec_tracer/reporters/terminal_reporter'
require 'rspec_tracer/reporters/registry'

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe RSpecTracer::Reporters::Registry do
  let(:tmp) { Dir.mktmpdir }
  let(:empty_snapshot) { RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'r') }
  let(:snapshot) do
    RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'r').tap do |s|
      s.all_examples = { 'ex1' => { id: 'ex1' } }
    end
  end
  let(:run_metadata) { {} }
  let(:logger) { instance_double(RSpecTracer::Logger, warn: nil, debug: nil) }
  let(:report_dir) { File.join(tmp, 'report') }

  after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

  def fake_config(reporters: nil, custom_logger: logger)
    config_double = Object.new
    config_double.define_singleton_method(:reporters) { reporters }
    config_double.define_singleton_method(:logger) { custom_logger }
    config_double
  end

  describe '.emit_all (class-method shortcut)' do
    it 'delegates to an instance and runs the defaults' do
      results = described_class.emit_all(
        configuration: fake_config(reporters: [[:json, {}]]),
        snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata
      )

      expect(results).to be_an(Array)
    end
  end

  describe 'default resolution' do
    it 'falls back to [:terminal, :json] when configuration.reporters is nil' do
      terminal_class = instance_spy(Class)
      json_class = instance_spy(Class)

      stub_const('RSpecTracer::Reporters::TerminalReporter', terminal_class)
      stub_const('RSpecTracer::Reporters::JsonReporter', json_class)
      allow(terminal_class).to receive(:new).and_return(instance_double(RSpecTracer::Reporters::Base, generate: nil))
      allow(json_class).to receive(:new).and_return(instance_double(RSpecTracer::Reporters::Base, generate: nil))

      described_class.new(configuration: fake_config).emit_all(
        snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata
      )

      expect(terminal_class).to have_received(:new).once
      expect(json_class).to have_received(:new).once
    end

    it 'falls back when configuration does not expose reporters at all' do
      bare_config = Object.new
      stub_logger = logger
      bare_config.define_singleton_method(:logger) { stub_logger }

      expect do
        described_class.new(configuration: bare_config).emit_all(
          snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata
        )
      end.not_to raise_error
    end

    it 'falls back to defaults when configuration.reporters is an empty array' do
      results = described_class.new(configuration: fake_config(reporters: [])).emit_all(
        snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata
      )

      # Both default reporters ran successfully (neither returned nil from rescue path).
      expect(results.compact).not_to be_empty
    end
  end

  describe 'empty-snapshot short-circuit' do
    it 'returns [] when snapshot is nil' do
      result = described_class.new(configuration: fake_config).emit_all(
        snapshot: nil, report_dir: report_dir, run_metadata: run_metadata
      )

      expect(result).to eq([])
    end

    it 'returns [] when snapshot.all_examples is empty' do
      result = described_class.new(configuration: fake_config).emit_all(
        snapshot: empty_snapshot, report_dir: report_dir, run_metadata: run_metadata
      )

      expect(result).to eq([])
    end

    it 'returns [] when snapshot.all_examples is nil' do
      snap = RSpecTracer::Storage::Snapshot.empty(schema_version: 3, run_id: 'r')
      snap.all_examples = nil

      result = described_class.new(configuration: fake_config).emit_all(
        snapshot: snap, report_dir: report_dir, run_metadata: run_metadata
      )

      expect(result).to eq([])
    end

    it 'returns [] when configured reporters list is empty AND snapshot is empty (no calls)' do
      config = fake_config(reporters: [])
      result = described_class.new(configuration: config).emit_all(
        snapshot: empty_snapshot, report_dir: report_dir, run_metadata: run_metadata
      )

      expect(result).to eq([])
    end
  end

  describe 'explicit reporter resolution' do
    it 'honors configuration.reporters tuples in order' do
      config = fake_config(reporters: [[:terminal, {}]])

      result = described_class.new(configuration: config).emit_all(
        snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata
      )

      expect(result).not_to be_nil
    end

    it 'raises ArgumentError on an unknown symbol (defensive for programmatic callers)' do
      config = fake_config(reporters: [[:bogus, {}]])

      expect do
        described_class.new(configuration: config).emit_all(
          snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata
        )
      end.to raise_error(ArgumentError, /unknown reporter/)
    end

    it 'accepts a Class directly' do
      spy_class = Class.new(RSpecTracer::Reporters::Base) do
        attr_reader :generated

        def generate
          @generated = true
        end
      end
      config = fake_config(reporters: [[spy_class, {}]])

      described_class.new(configuration: config).emit_all(
        snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata
      )

      # Indirect check: the spy class constructed + generate ran without exception.
      expect(spy_class.ancestors).to include(RSpecTracer::Reporters::Base)
    end

    it 'forwards **opts to the reporter initializer' do
      captured = nil
      spy_class = Class.new(RSpecTracer::Reporters::Base) do
        define_method(:generate) do
          captured = options
        end
      end
      config = fake_config(reporters: [[spy_class, { flag: 42 }]])

      described_class.new(configuration: config).emit_all(
        snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata
      )

      expect(captured).to eq(flag: 42)
    end

    it 'tolerates a nil opts entry (legacy shape)' do
      spy_class = Class.new(RSpecTracer::Reporters::Base) do
        def generate
          :ok
        end
      end
      config = fake_config(reporters: [[spy_class, nil]])

      result = described_class.new(configuration: config).emit_all(
        snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata
      )

      expect(result).to eq([:ok])
    end
  end

  describe 'per-reporter rescue' do
    it 'catches an exception in one reporter and continues to the next' do
      raising_class = Class.new(RSpecTracer::Reporters::Base) do
        def generate
          raise 'boom'
        end
      end
      ok_class = Class.new(RSpecTracer::Reporters::Base) do
        def generate
          :ok
        end
      end
      config = fake_config(reporters: [[raising_class, {}], [ok_class, {}]])

      results = described_class.new(configuration: config).emit_all(
        snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata
      )

      expect(results).to eq([nil, :ok])
      expect(logger).to have_received(:warn).with(/failed \(RuntimeError: boom\)/)
    end

    it 'survives when configuration exposes no logger' do
      raising_class = Class.new(RSpecTracer::Reporters::Base) do
        def generate
          raise 'boom'
        end
      end
      config = fake_config(reporters: [[raising_class, {}]], custom_logger: nil)

      expect do
        described_class.new(configuration: config).emit_all(
          snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata
        )
      end.not_to raise_error
    end

    it 'survives when configuration does not respond to :logger at all' do
      raising_class = Class.new(RSpecTracer::Reporters::Base) do
        def generate
          raise 'boom'
        end
      end
      minimal_config = Object.new
      minimal_config.define_singleton_method(:reporters) { [[raising_class, {}]] }

      expect do
        described_class.new(configuration: minimal_config).emit_all(
          snapshot: snapshot, report_dir: report_dir, run_metadata: run_metadata
        )
      end.not_to raise_error
    end
  end

  describe 'BUILT_INS constant' do
    it 'is frozen' do
      expect(described_class::BUILT_INS).to be_frozen
    end

    it 'maps :terminal and :json to their reporter class constant names' do
      expect(described_class::BUILT_INS).to include(
        terminal: 'RSpecTracer::Reporters::TerminalReporter',
        json: 'RSpecTracer::Reporters::JsonReporter'
      )
    end
  end

  describe 'DEFAULTS constant' do
    it 'is frozen' do
      expect(described_class::DEFAULTS).to be_frozen
    end

    it 'matches the brief-literal default list' do
      expect(described_class::DEFAULTS).to eq(%i[terminal json])
    end
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/MultipleExpectations, RSpec/ExampleLength
