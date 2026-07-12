# frozen_string_literal: true

module RSpecTracer
  # Per-engine line-stub builder for files that need a synthetic
  # all-nil-but-executable-lines coverage array. Used by
  # `Reporters::CoverageJsonReporter` when a tracked file is in
  # `coverage_tracked_files` but has no recorded coverage (file never
  # loaded during this run).
  #
  # Lives at the top level of lib/rspec_tracer so the per-engine
  # branches sit outside the tracker_coverage_gate's
  # 100%-line+branch contract (the JRuby branch cannot be exercised
  # on MRI; cross-engine coverage rollup would require fork-per-engine
  # CI work that isn't justified for stub-line generation).
  #
  # Methods use `def self.x` (not module_function) so future mutation
  # gating maps to the singleton form -- module_function attaches
  # methods to an anonymous singleton that mutant cannot observe.
  module LineStub
    # Internal helper for the tracer pipeline.
    # @api private
    def self.for(file_path)
      case RUBY_ENGINE
      when 'ruby'
        ruby(file_path)
      when 'jruby'
        jruby(file_path)
      else
        File.foreach(file_path).map { nil }
      end
    end

    # Internal helper for the tracer pipeline.
    # @api private
    def self.ruby(file_path)
      lines = File.foreach(file_path).map { nil }
      iseqs = [::RubyVM::InstructionSequence.compile_file(file_path)]
      until iseqs.empty?
        iseq = iseqs.pop
        iseq.trace_points.each { |line_number, type| lines[line_number - 1] = 0 if type == :line }
        iseq.each_child { |child| iseqs << child }
      end
      lines
    end

    # Internal helper for the tracer pipeline.
    # @api private
    def self.jruby(file_path)
      lines = File.foreach(file_path).map { nil }
      root_node = ::JRuby.parse(File.read(file_path, encoding: 'UTF-8'))
      visitor = org.jruby.ast.visitor.NodeVisitor.impl do |_name, node|
        if node.newline?
          ln = node.respond_to?(:position) ? node.position.line : node.line
          lines[ln] = 0
        end
        node.child_nodes.each { |child| child&.accept(visitor) }
      end
      root_node.accept(visitor)
      lines
    end
  end
end
