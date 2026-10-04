require "../spec_helper"
require "../../src/testing/assert_module"

module Adjutant
  # Runs `source` after `require "assert"` and returns each assertion's
  # failure message, in order; a passing assertion contributes `nil`.
  private def self.assert_messages(source : String) : Array(String?)
    interp, _ = make_interp
    mod = ::Testing::AssertModule.new
    interp.modules.register(mod)
    interp.eval("require \"assert\"\n" + source)
    mod.results.map(&.message)
  end

  describe ::Testing::AssertModule do
    describe "failure messages" do
      it "render values with the script's own inspect" do
        messages = assert_messages(<<-RUBY)
          assert_equal([1, "a"], [1, "b"])
          assert_not_equal([2], [2])
          assert_nil([3])
          assert_false([4])
          RUBY
        messages.should eq [
          %(expected [1, "a"], got [1, "b"]),
          "both are [2]",
          "got [3]",
          "got [4]",
        ]
      end

      it "use a script class's inspect" do
        messages = assert_messages(<<-RUBY)
          class Box
            def initialize(n)
              @n = n
            end

            def inspect
              "#<Box \#{@n}>"
            end
          end
          assert_equal(1, Box.new(7))
          RUBY
        messages.should eq [%(expected 1, got #<Box 7>)]
      end

      it "still record the failure when inspect raises" do
        messages = assert_messages(<<-RUBY)
          class Broken
            def inspect
              raise "no inspect"
            end
          end
          assert_equal(1, Broken.new)
          RUBY
        messages.size.should eq 1
        messages.first.to_s.should start_with "expected 1, got "
      end
    end
  end
end
