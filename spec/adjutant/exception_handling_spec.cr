require "../spec_helper"

module Adjutant
  # Chunk 1 of typed exceptions: begin/rescue actually catching a raised
  # error, not just parsing/compiling one. Prior to this, Op::Try set
  # Frame#rescue_ip but execute() never consulted it, so any runtime
  # error (division by zero, explicit raise, native errors) unwound
  # straight past the VM regardless of an enclosing rescue.
  #
  # Error values are string messages for now (Op::PushError stub) —
  # typed exception objects land in a later chunk once base RubyClass
  # hierarchy (StandardError, TypeError, etc.) exists.
  describe "begin/rescue error catching" do
    it "catches a runtime error (division by zero)" do
      result = eval(<<-RUBY)
        begin
          1 / 0
        rescue e
          :caught
        end
      RUBY
      result.symbol?.should be_true
      result.as_sym.name.should eq "caught"
    end

    it "does not touch the rescue body on success" do
      eval(<<-RUBY).should eq Value.int(2_i64)
        begin
          1 + 1
        rescue e
          :failed
        end
      RUBY
    end

    it "binds the rescue variable to the error message" do
      eval(<<-RUBY).should eq Value.string("divided by 0")
        begin
          1 / 0
        rescue e
          e
        end
      RUBY
    end

    it "catches an explicit raise with a custom message" do
      eval(<<-RUBY).should eq Value.string("boom")
        begin
          raise "boom"
        rescue e
          e
        end
      RUBY
    end

    it "stops executing the begin body at the point of the error" do
      eval(<<-RUBY).should eq Value.bool(false)
        ran_after = false
        begin
          1 / 0
          ran_after = true
        rescue e
          nil
        end
        ran_after
      RUBY
    end

    it "catches an error raised one call frame deep" do
      result = eval(<<-RUBY)
        def blow_up
          1 / 0
        end

        begin
          blow_up()
        rescue e
          :caught
        end
      RUBY
      result.symbol?.should be_true
      result.as_sym.name.should eq "caught"
    end

    it "catches an error raised several call frames deep" do
      result = eval(<<-RUBY)
        def level_three
          1 / 0
        end

        def level_two
          level_three()
        end

        def level_one
          level_two()
        end

        begin
          level_one()
        rescue e
          :caught
        end
      RUBY
      result.symbol?.should be_true
      result.as_sym.name.should eq "caught"
    end

    it "leaves the stack clean after unwinding a deep error" do
      # A regression guard: unwinding multiple frames must also unwind
      # their stack contents, or subsequent stack ops would be corrupted.
      eval(<<-RUBY).should eq Value.int(5_i64)
        def blow_up
          1 / 0
        end

        begin
          blow_up()
        rescue e
          nil
        end

        2 + 3
      RUBY
    end

    it "still propagates an uncaught error past a frame with no rescue handler" do
      expect_raises(RuntimeError, /divided by 0/) do
        eval(<<-RUBY)
          1 / 0
        RUBY
      end
    end
  end
end
