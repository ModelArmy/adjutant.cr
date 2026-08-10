require "../../spec_helper"

module Adjutant
  describe Interpreter do
    describe "multi-level closures (Step 2 — resolve_outer walks the full chain)" do
      # Confirmed broken 2026-08-10 against real runs — see SCOPE.md's
      # "Closures / block scoping" entry and Step 1's OuterChain
      # foundation (this session). These mirror
      # spec/scripts/language/multi_closure.rb and
      # spec/scripts/language/nested_block_closure.rb exactly (the
      # person's own reproductions), re-enabled here as permanent
      # crystal-spec coverage rather than only ad hoc scripts.

      it "single-level lambda closure still works (control case)" do
        eval(<<-RUBY).should eq Value.int(11_i64)
        def single_level
          x = 10
          make_inc = -> { x + 1 }
          make_inc.call
        end
        single_level
        RUBY
      end

      it "a lambda created inside a block reads a variable two scopes up" do
        eval(<<-RUBY).should eq Value.int(11_i64)
        def two_level
          x = 10
          result = nil
          [1].each do |i|
            inc = -> { x + 1 }
            result = inc.call
          end
          result
        end
        two_level
        RUBY
      end

      it "a lambda created inside a block WRITES a variable two scopes up, and it's visible after the block returns" do
        eval(<<-RUBY).should eq Value.int(99_i64)
        def two_level_write
          x = 10
          [1].each do |i|
            setter = -> { x = 99 }
            setter.call
          end
          x
        end
        two_level_write
        RUBY
      end

      it "single-level block closure still works (control case)" do
        eval(<<-RUBY).should eq Value.int(11_i64)
        def single_level_block
          x = 10
          result = nil
          [1].each do |i|
            result = x + 1
          end
          result
        end
        single_level_block
        RUBY
      end

      it "a block nested two levels deep (no lambda at all) reads a variable two scopes up" do
        eval(<<-RUBY).should eq Value.int(11_i64)
        def two_level_block
          x = 10
          result = nil
          [1].each do |i|
            [1].each do |j|
              result = x + 1
            end
          end
          result
        end
        two_level_block
        RUBY
      end

      it "a block nested three levels deep reads a variable three scopes up" do
        eval(<<-RUBY).should eq Value.int(11_i64)
        def three_level_block
          x = 10
          result = nil
          [1].each do |i|
            [1].each do |j|
              [1].each do |k|
                result = x + 1
              end
            end
          end
          result
        end
        three_level_block
        RUBY
      end

      it "a block nested two levels deep WRITES a variable two scopes up, and it's visible after both blocks return" do
        eval(<<-RUBY).should eq Value.int(99_i64)
        def two_level_block_write
          x = 10
          [1].each do |i|
            [1].each do |j|
              x = 99
            end
          end
          x
        end
        two_level_block_write
        RUBY
      end

      it "plain reassignment of an already-existing outer variable writes THROUGH to it, not a new shadowed local" do
        # x = 2 inside the block does NOT create a fresh local — real
        # Ruby (and Adjutant, matching it) reuses the EXISTING outer
        # x, since it's a plain assignment, not a block parameter.
        eval(<<-RUBY).should eq Value.int(2_i64)
        def foo
          x = 1
          result = nil
          [1].each do |i|
            x = 2
            [1].each do |j|
              result = x
            end
          end
          result
        end
        foo
        RUBY
      end

      it "a name shadowed by a NEARER block PARAMETER (genuine fresh local) resolves to the near one, not the far one" do
        eval(<<-RUBY).should eq Value.int(2_i64)
        def foo
          x = 1
          result = nil
          [2].each do |x|
            [1].each do |j|
              result = x
            end
          end
          result
        end
        foo
        RUBY
      end
    end
  end
end
