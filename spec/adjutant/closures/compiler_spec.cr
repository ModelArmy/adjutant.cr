require "../../spec_helper"

module Adjutant
  # A block/lambda literal compiles to its OWN separate Chunk (via
  # Compiler.compile_proc), referenced from its creation site by one
  # Op::MakeProc pointing into the constant pool — never inlined into
  # the surrounding chunk's own bytecode. Descends `levels` nested
  # MakeProc hops (first Op::MakeProc found at each level) to reach
  # the chunk actually belonging to a block/lambda nested that deep.
  private def self.descend_into_proc(chunk : Chunk, levels : Int32 = 1) : Chunk
    levels.times do
      idx = chunk.code.index { |i| i.op == Op::MakeProc }
      raise "no Op::MakeProc found while descending into nested proc chunk" unless idx
      chunk = chunk.consts[chunk.code[idx].c].as_proc.chunk
    end
    chunk
  end

  describe Compiler do
    describe "multi-level closures (Step 2 — CompilerScope#resolve_outer walks the full chain)" do
      # Found 2026-08-10 (SCOPE.md's "Closures / block scoping" entry):
      # resolve_outer used to check only the immediate parent scope's
      # own vars and give up — these specs assert the walk now finds
      # a name at ANY depth, and that the DEPTH it reports actually
      # increases with real nesting (not just "found somewhere").

      it "a block reading its immediate enclosing method's local emits depth 0" do
        foo_chunk = def_proc_chunk(<<-RUBY)
          def foo
            x = 1
            [1].each do |i|
              x
            end
          end
        RUBY
        block_chunk = descend_into_proc(foo_chunk, 1)
        inst = block_chunk.code.find { |i| i.op == Op::GetOuter }
        inst.should_not be_nil
        inst.not_nil!.a.should eq 0_u8
      end

      it "a block nested two levels deep reading the method's local emits depth 1" do
        foo_chunk = def_proc_chunk(<<-RUBY)
          def foo
            x = 1
            [1].each do |i|
              [1].each do |j|
                x
              end
            end
          end
        RUBY
        inner_chunk = descend_into_proc(foo_chunk, 2)
        inst = inner_chunk.code.find { |i| i.op == Op::GetOuter }
        inst.should_not be_nil
        inst.not_nil!.a.should eq 1_u8
      end

      it "a block nested three levels deep reading the method's local emits depth 2" do
        foo_chunk = def_proc_chunk(<<-RUBY)
          def foo
            x = 1
            [1].each do |i|
              [1].each do |j|
                [1].each do |k|
                  x
                end
              end
            end
          end
        RUBY
        inner_chunk = descend_into_proc(foo_chunk, 3)
        inst = inner_chunk.code.find { |i| i.op == Op::GetOuter }
        inst.should_not be_nil
        inst.not_nil!.a.should eq 2_u8
      end

      it "a lambda nested inside a block reading the method's local emits depth 1, same as a plain block would" do
        foo_chunk = def_proc_chunk(<<-RUBY)
          def foo
            x = 1
            [1].each do |i|
              inc = -> { x }
            end
          end
        RUBY
        lambda_chunk = descend_into_proc(foo_chunk, 2)
        inst = lambda_chunk.code.find { |i| i.op == Op::GetOuter }
        inst.should_not be_nil
        inst.not_nil!.a.should eq 1_u8
      end

      it "a name shadowed by a NEARER block PARAMETER (genuine fresh local) resolves to the near one, not the far one" do
        # Plain reassignment of an already-existing outer name (`x =
        # 2` where x already exists outside) does NOT create a new
        # local — real Ruby writes THROUGH to the existing outer x
        # (see the VM-level "shadowed by a nearer scope" spec for
        # that distinction). A block PARAMETER, unlike reassignment,
        # always creates a genuinely fresh local scoped to that block
        # — the correct way to test "nearest actually wins."
        foo_chunk = def_proc_chunk(<<-RUBY)
          def foo
            x = 1
            [2].each do |x|
              [1].each do |j|
                x
              end
            end
          end
        RUBY
        inner_chunk = descend_into_proc(foo_chunk, 2)
        inst = inner_chunk.code.find { |i| i.op == Op::GetOuter }
        inst.should_not be_nil
        inst.not_nil!.a.should eq 0_u8
      end

      it "SetOuter (write) also carries the correct depth for nested blocks" do
        foo_chunk = def_proc_chunk(<<-RUBY)
          def foo
            x = 1
            [1].each do |i|
              [1].each do |j|
                x = 99
              end
            end
          end
        RUBY
        inner_chunk = descend_into_proc(foo_chunk, 2)
        inst = inner_chunk.code.find { |i| i.op == Op::SetOuter }
        inst.should_not be_nil
        inst.not_nil!.a.should eq 1_u8
      end
    end
  end
end
