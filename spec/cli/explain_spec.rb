# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'json'
require 'fileutils'

require 'rspec_tracer/cli/explain'

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable
RSpec.describe RSpecTracer::CLI::Explain do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  describe '.run' do
    it 'prints help when no args given' do
      expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
      expect(stdout.string).to include('Usage: rspec-tracer explain')
    end

    it 'prints help on -h / --help' do
      %w[-h --help].each do |flag|
        out = StringIO.new
        expect(described_class.run([flag], stdout: out, stderr: stderr)).to eq(0)
        expect(out.string).to include('Usage: rspec-tracer explain')
      end
    end

    it 'returns 1 with a clear error when no last_run.json exists' do
      Dir.mktmpdir do |dir|
        allow(RSpecTracer).to receive(:cache_path).and_return(dir)
        expect(described_class.run(%w[anything], stdout: stdout, stderr: stderr)).to eq(1)
        expect(stderr.string).to include('no last_run.json')
      end
    end

    it 'returns 1 when the run_id directory is missing' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'last_run.json'), JSON.dump('run_id' => 'missing_run'))
        allow(RSpecTracer).to receive(:cache_path).and_return(dir)
        expect(described_class.run(%w[any], stdout: stdout, stderr: stderr)).to eq(1)
        expect(stderr.string).to include('directory missing')
      end
    end

    context 'with a populated cache' do
      let(:run_id) { 'run_xyz' }

      before do
        @tmp_dir = Dir.mktmpdir
        run_dir = File.join(@tmp_dir, run_id)
        FileUtils.mkdir_p(run_dir)
        File.write(File.join(@tmp_dir, 'last_run.json'), JSON.dump('run_id' => run_id))
        File.write(File.join(run_dir, 'all_examples.json'), JSON.dump(
                                                              'a/spec.rb[1:1]' => {
                                                                'example_id' => 'a/spec.rb[1:1]',
                                                                'full_description' => 'Foo does bar',
                                                                'rerun_file_name' => './spec/foo_spec.rb',
                                                                'rerun_line_number' => 12,
                                                                'execution_result' => { 'status' => 'passed' },
                                                                'run_reason' => 'changed'
                                                              }
                                                            ))
        File.write(File.join(run_dir, 'dependency.json'),
                   JSON.dump('a/spec.rb[1:1]' => ['./spec/foo_spec.rb', './lib/foo.rb']))
        allow(RSpecTracer).to receive(:cache_path).and_return(@tmp_dir)
      end

      after { FileUtils.rm_rf(@tmp_dir) if @tmp_dir }

      it 'returns 1 when no example matches the query' do
        expect(described_class.run(%w[totally_bogus], stdout: stdout, stderr: stderr)).to eq(1)
        expect(stderr.string).to include('no example matching')
      end

      it 'matches by exact example_id and prints the full explanation' do
        expect(described_class.run(['a/spec.rb[1:1]'], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('Foo does bar')
        expect(stdout.string).to include('passed')
        expect(stdout.string).to include('changed')
        expect(stdout.string).to include('./lib/foo.rb')
      end

      it 'falls back to substring match on full_description' do
        expect(described_class.run(%w[Foo], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('Foo does bar')
      end
    end

    it 'rescues StandardError and returns 1' do
      allow(RSpecTracer).to receive(:cache_path).and_raise(StandardError, 'cache resolve boom')

      expect(described_class.run(%w[any], stdout: stdout, stderr: stderr)).to eq(1)
      expect(stderr.string).to include('explain:')
      expect(stderr.string).to include('boom')
    end
  end

  describe '.read_json' do
    it 'returns {} for missing file' do
      expect(described_class.read_json('/missing/file.json')).to eq({})
    end

    it 'returns {} when content is not a Hash' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'arr.json')
        File.write(path, JSON.dump(%w[a b]))
        expect(described_class.read_json(path)).to eq({})
      end
    end
  end

  describe '.find_example' do
    let(:examples) do
      {
        'a' => { 'full_description' => 'Foo does bar' },
        'b' => { 'full_description' => 'Baz works correctly' }
      }
    end

    it 'returns the meta on exact id match' do
      expect(described_class.find_example(examples, 'a')).to eq(examples['a'])
    end

    it 'returns the meta on substring match against description' do
      expect(described_class.find_example(examples, 'Baz')).to eq(examples['b'])
    end

    it 'returns nil on no match' do
      expect(described_class.find_example(examples, 'totally_unrelated')).to be_nil
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable
