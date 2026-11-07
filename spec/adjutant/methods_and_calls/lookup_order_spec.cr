require "../../spec_helper"

module Adjutant
  describe "method lookup across script and native methods, as Ruby's ancestors order" do
    it "runs a class's own native over a top-level def of the same name, called with a receiver" do
      src = <<-RUBY
        def first
          :top_level
        end
        (1..3).first.inspect
        RUBY
      eval(src).as_string.should eq "1"
    end

    it "runs a class's own native over a top-level def of the same name, called on self" do
      src = <<-RUBY
        def message
          "top-level"
        end

        class AppError < StandardError
          def detail
            "\#{message}!"
          end
        end
        AppError.new("bad").detail.inspect
        RUBY
      eval(src).as_string.should eq %("bad!")
    end

    it "runs a class's own native over a method of a module included at the top level" do
      src = <<-RUBY
        module Helpers
          def first
            :helper
          end
        end
        include Helpers
        (1..3).first.inspect
        RUBY
      eval(src).as_string.should eq "1"
    end

    it "passes self to a builtin class's native method called without a receiver" do
      src = <<-RUBY
        class Probe
          def show
            [inspect, to_s.class]
          end
        end

        class AppError < StandardError
          def detail
            message
          end
        end
        [Probe.new.show, AppError.new("bad").detail].inspect
        RUBY
      eval(src).as_string.should eq %([["#<Probe>", String], "bad"])
    end

    it "reaches Object's public script methods from a builtin value" do
      src = <<-RUBY
        module Helpers
          def doubled
            self * 2
          end
        end
        include Helpers
        5.doubled.inspect
        RUBY
      eval(src).as_string.should eq "10"
    end

    it "raises NoMethodError for a top-level def called on a builtin value" do
      src = <<-RUBY
        def doubled
          self * 2
        end

        begin
          5.doubled
        rescue NoMethodError => e
          e.class.inspect
        end
        RUBY
      eval(src).as_string.should eq "NoMethodError"
    end

    it "runs a class's own native class method over one defined on Object" do
      src = <<-RUBY
        def Object.now
          :script
        end
        [Time.now.class, Object.now].inspect
        RUBY
      eval(src).as_string.should eq "[Time, :script]"
    end

    it "runs a subclass's script method over its superclass's native" do
      src = <<-RUBY
        class AppError < StandardError
          def message
            "own"
          end
        end
        AppError.new("bad").message.inspect
        RUBY
      eval(src).as_string.should eq %("own")
    end
  end
end
