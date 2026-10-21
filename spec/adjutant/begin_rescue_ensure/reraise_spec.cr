require "../../spec_helper"

module Adjutant
  # `src`, which defines `run`, then `run`'s result as `inspect` prints it.
  private def self.reraise_outcome(src : String) : String
    eval("#{src}\nrun.inspect").as_string
  end

  describe "a bare `raise`, as MRI's rb_f_raise" do
    describe "re-raises the exception being handled" do
      it "keeping its class and message, with or without parentheses" do
        {"raise", "raise()"}.each do |bare|
          src = <<-RUBY
          def run
            begin
              begin
                raise ArgumentError, "inner"
              rescue ArgumentError
                #{bare}
              end
            rescue => e
              [e.class, e.message]
            end
          end
          RUBY
          reraise_outcome(src).should eq %([ArgumentError, "inner"])
        end
      end

      it "as the same object" do
        src = <<-RUBY
        def run
          first = nil
          begin
            begin
              raise ArgumentError, "inner"
            rescue => e
              first = e
              raise
            end
          rescue => again
            again.equal?(first)
          end
        end
        RUBY
        reraise_outcome(src).should eq "true"
      end

      it "so an outer rescue matches its class, as UNSUPPORTED.md's alternative to retry relies on" do
        src = <<-RUBY
        class Flaky < StandardError
        end

        def run
          attempts = 0
          begin
            loop do
              attempts += 1
              begin
                raise Flaky, "flaky"
              rescue StandardError
                raise if attempts >= 3
              end
            end
          rescue Flaky => e
            [attempts, e.message]
          end
        end
        RUBY
        reraise_outcome(src).should eq %([3, "flaky"])
      end

      it "from a method called in the rescue body" do
        src = <<-RUBY
        def rethrow
          raise
        end

        def run
          begin
            begin
              raise ArgumentError, "inner"
            rescue
              rethrow
            end
          rescue => e
            [e.class, e.message]
          end
        end
        RUBY
        reraise_outcome(src).should eq %([ArgumentError, "inner"])
      end

      it "from a block a native method runs in the rescue body" do
        src = <<-RUBY
        def run
          begin
            begin
              raise ArgumentError, "inner"
            rescue
              [1].each { |_item| raise }
            end
          rescue => e
            [e.class, e.message]
          end
        end
        RUBY
        reraise_outcome(src).should eq %([ArgumentError, "inner"])
      end

      it "of the outer rescue once a nested begin in its body has finished" do
        src = <<-RUBY
        def run
          begin
            begin
              raise ArgumentError, "outer"
            rescue
              begin
                raise TypeError, "inner"
              rescue
              end
              raise
            end
          rescue => e
            [e.class, e.message]
          end
        end
        RUBY
        reraise_outcome(src).should eq %([ArgumentError, "outer"])
      end

      it "that an ensure body was entered with" do
        src = <<-RUBY
        def run
          begin
            begin
              raise ArgumentError, "inner"
            ensure
              raise
            end
          rescue => e
            [e.class, e.message]
          end
        end
        RUBY
        reraise_outcome(src).should eq %([ArgumentError, "inner"])
      end
    end

    describe "raises RuntimeError, \"unhandled exception\", with nothing being handled" do
      it "outside any rescue" do
        src = <<-RUBY
        def run
          begin
            raise
          rescue => e
            [e.class, e.message]
          end
        end
        RUBY
        reraise_outcome(src).should eq %([RuntimeError, "unhandled exception"])
      end

      it "after an exception has been handled and its rescue has finished" do
        src = <<-RUBY
        def run
          begin
            raise ArgumentError, "done"
          rescue
          end
          begin
            raise
          rescue => e
            [e.class, e.message]
          end
        end
        RUBY
        reraise_outcome(src).should eq %([RuntimeError, "unhandled exception"])
      end

      it "in an ensure body entered without an exception" do
        src = <<-RUBY
        def run
          begin
            begin
              :ok
            ensure
              raise
            end
          rescue => e
            [e.class, e.message]
          end
        end
        RUBY
        reraise_outcome(src).should eq %([RuntimeError, "unhandled exception"])
      end
    end
  end
end
