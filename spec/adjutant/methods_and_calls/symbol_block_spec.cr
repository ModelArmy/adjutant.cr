require "../../spec_helper"

module Adjutant
  # The diagnostic code `source` fails to parse with, or nil if it parses.
  private def self.symbol_block_parse_code(source : String) : String?
    Parser.new(source).parse
    nil
  rescue ex : ParseError
    ex.diagnostic.try(&.code)
  end

  # The unresolved-call findings the risk walker reports for `source`.
  private def self.symbol_block_unresolved(source : String) : Array(String)
    interp, _ = make_interp
    tree = RiskWalker.new(interp).walk_body(Parser.new(source).parse)
    RiskAggregator.all_findings(tree)
      .select(&.description.starts_with?("unresolved call: "))
      .map(&.description)
  end

  describe "a `&:name` block argument" do
    describe "as Ruby's Symbol#to_proc" do
      it "calls the named method on each element" do
        eval(%(%w[a b].map(&:upcase).inspect)).as_string.should eq %(["A", "B"])
      end

      it "takes a predicate name" do
        eval("[1, 2, 3, 4].select(&:even?).inspect").as_string.should eq "[2, 4]"
      end

      it "never spreads a lone Array element across arguments" do
        eval("[[1, 2], [3, 4]].map(&:first).inspect").as_string.should eq "[1, 3]"
      end

      it "passes every yielded value after the first as an argument" do
        eval("[1, 2, 3].inject(&:+)").as_int.should eq 6_i64
      end

      it "calls a script class's own method" do
        src = <<-RUBY
        class Item
          def initialize(n)
            @n = n
          end

          def label
            "item \#{@n}"
          end
        end
        [Item.new(1), Item.new(2)].map(&:label).inspect
        RUBY
        eval(src).as_string.should eq %(["item 1", "item 2"])
      end

      it "is what a script method's `yield` runs" do
        src = <<-RUBY
        def twice
          [yield(2), yield(3)]
        end
        twice(&:to_s).inspect
        RUBY
        eval(src).as_string.should eq %(["2", "3"])
      end

      it "receives two yielded values as receiver and argument" do
        src = <<-RUBY
        def pair
          yield 10, 3
        end
        pair(&:-)
        RUBY
        eval(src).as_int.should eq 7_i64
      end

      it "follows keyword arguments" do
        src = <<-RUBY
        def apply(value, by:)
          yield value, by
        end
        apply(10, by: 4, &:-)
        RUBY
        eval(src).as_int.should eq 6_i64
      end

      it "is read without parentheses after a receiver's method" do
        src = <<-RUBY
        (%w[a b].map &:upcase).inspect
        RUBY
        eval(src).as_string.should eq %(["A", "B"])
      end

      it "is read without parentheses after a method that isn't a local" do
        src = <<-RUBY
        def twice
          [yield(2), yield(3)]
        end
        (twice &:to_s).inspect
        RUBY
        eval(src).as_string.should eq %(["2", "3"])
      end

      it "raises for a method the element lacks" do
        expect_raises(RuntimeError, /frobnicate/) { eval("[1].map(&:frobnicate)") }
      end

      it "raises when yielded no values, having no receiver" do
        src = <<-RUBY
        def bare
          yield
        end
        bare(&:upcase)
        RUBY
        expect_raises(RuntimeError) { eval(src) }
      end
    end

    describe "where Ruby or Adjutant refuses it" do
      it "rejects a block literal as well, as Ruby does" do
        symbol_block_parse_code(%(%w[a].map(&:upcase) { |word| word })).should eq "P009"
      end

      it "rejects an argument after it, as Ruby does" do
        symbol_block_parse_code("foo(&:upcase, 1)").should eq "P001"
      end

      it "rejects `&` before a lambda (U001)" do
        symbol_block_parse_code("fn = ->(x) { x }\n[1].map(&fn)").should eq "U001"
      end

      it "rejects `&` before a variable, even one holding a Symbol (U001)" do
        symbol_block_parse_code("name = :upcase\n%w[a].map(&name)").should eq "U001"
      end
    end

    describe "as the risk walker sees it" do
      it "reports the same unresolved call as the equivalent block" do
        shorthand = symbol_block_unresolved("items = fetch_items\nitems.each(&:frobnicate)")
        written_out = symbol_block_unresolved("items = fetch_items\nitems.each { |item| item.frobnicate }")
        shorthand.should eq written_out
        shorthand.any?(&.includes?("frobnicate")).should be_true
      end
    end
  end
end
