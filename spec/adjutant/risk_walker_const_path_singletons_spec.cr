require "../spec_helper"

module Adjutant
  private def self.register_risky_module(interp : Interpreter, name : String, risk : RiskProfile) : Nil
    interp.modules.register(name) do |i|
      i.define_native(name, risk: risk) { |_| Value.nil_value }
    end
    interp.modules.require(name, interp)
  end

  # Registers the three native functions risky_example_0{2..5}.rb rely
  # on, matching samples/scripts/risky_example.rb's shape: delete_file
  # is Error/DeletesFiles/irreversible, puts_args is pure, fetch_url is
  # Warning/NetworkEgress.
  private def self.setup_risky_sample_fns(interp : Interpreter) : Nil
    register_risky_module(interp, "delete_file",
      RiskProfile.new(tags: Set{RiskTag::DeletesFiles}, reversible: Reversibility::No, severity: Severity::Error))
    register_risky_module(interp, "puts_args", RiskProfile.none)
    register_risky_module(interp, "fetch_url",
      RiskProfile.new(tags: Set{RiskTag::NetworkEgress}, reversible: Reversibility::Yes, severity: Severity::Warning))
  end

  # Regression coverage for the four risky_example_0{2,3,4,5}.rb
  # variants that surfaced two RiskWalker bugs together:
  #
  #   1. `def self.foo` inside a class/module body registered into
  #      @top_level_procs (the WRONG table — a global scope-crossing
  #      bug) instead of the class's own singleton_methods table.
  #   2. `M::A` (a ConstPath receiver) was never resolved at all, in
  #      either RiskWalker or TypeInference — always UnknownType /
  #      RiskUnresolved, even when M::A was defined right there in the
  #      same script.
  #
  # Each risky_example script pairs `delete_file()`/`puts_args()`
  # behind an if, called through `cleanup`, reached via a different
  # receiver shape. The correct assessment is IDENTICAL across all
  # four shapes: Error/DeletesFiles reachable via the if-branch, on
  # top of the unconditional NetworkEgress from the iterated
  # fetch_url loop — reflecting that these are the same program
  # semantically, just different receiver syntax.
  describe "RiskWalker: def self.foo registration (risky_example_03)" do
    it "def self.foo inside a class body registers as a singleton method, not a global" do
      interp, _ = make_interp
      setup_risky_sample_fns(interp)
      walker = RiskWalker.new(interp)
      body = Parser.new(<<-RUBY).parse
        class A
          def self.cleanup(force)
            if force
              delete_file()
            end
          end
        end
        A.cleanup(true)
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Error
      summary.tags.should eq Set{RiskTag::DeletesFiles}
    end

    it "the same def self.foo body is NOT reachable as a bare top-level call" do
      interp, _ = make_interp
      setup_risky_sample_fns(interp)
      walker = RiskWalker.new(interp)
      body = Parser.new(<<-RUBY).parse
        class A
          def self.cleanup(force)
            delete_file()
          end
        end
        cleanup(true)
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      # If DefSingleton still leaked into @top_level_procs under the
      # bare name "cleanup", this bare call would find it and surface
      # DeletesFiles — it must not; a bare, receiverless "cleanup"
      # was never defined at top level in this script.
      summary.severity.should eq Severity::Error
      summary.path.first.should contain "unresolved"
    end

    it "full risky_example_03 shape: fetch_url loop + A.cleanup(true) both surface" do
      interp, _ = make_interp
      setup_risky_sample_fns(interp)
      walker = RiskWalker.new(interp)
      body = Parser.new(<<-RUBY).parse
        class A
          def self.cleanup(force)
            if force
              delete_file()
            else
              puts_args()
            end
          end
        end

        i = 0
        while i < 3
          fetch_url()
          i += 1
        end

        A.cleanup(true)
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Error
      summary.tags.should eq Set{RiskTag::DeletesFiles, RiskTag::NetworkEgress}
      findings = RiskAggregator.all_findings(walker.walk_body(Parser.new(<<-RUBY).parse))
        class A
          def self.cleanup(force)
            if force
              delete_file()
            else
              puts_args()
            end
          end
        end

        i = 0
        while i < 3
          fetch_url()
          i += 1
        end

        A.cleanup(true)
      RUBY
      findings.map(&.profile.severity).should contain Severity::Warning # fetch_url
      findings.map(&.profile.severity).should contain Severity::Error   # delete_file
    end
  end

  describe "RiskWalker/TypeInference: ConstPath resolution (risky_example_04, 05)" do
    it "M::A.method resolves the same as A.method would, once M::A is defined" do
      interp, _ = make_interp
      setup_risky_sample_fns(interp)
      walker = RiskWalker.new(interp)
      body = Parser.new(<<-RUBY).parse
        module M
          class A
            def self.cleanup(force)
              if force
                delete_file()
              end
            end
          end
        end
        M::A.cleanup(true)
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Error
      summary.tags.should eq Set{RiskTag::DeletesFiles}
    end

    it "full risky_example_04 shape: fetch_url loop + M::A.cleanup(true)" do
      interp, _ = make_interp
      setup_risky_sample_fns(interp)
      walker = RiskWalker.new(interp)
      body = Parser.new(<<-RUBY).parse
        module M
          class A
            def self.cleanup(force)
              if force
                delete_file()
              else
                puts_args()
              end
            end
          end
        end

        i = 0
        while i < 3
          fetch_url()
          i += 1
        end

        M::A.cleanup(true)
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Error
      summary.tags.should eq Set{RiskTag::DeletesFiles, RiskTag::NetworkEgress}
    end

    it "M::A.new.method resolves via ConstPath through both TypeInference and RiskWalker (risky_example_05)" do
      interp, _ = make_interp
      setup_risky_sample_fns(interp)
      walker = RiskWalker.new(interp)
      body = Parser.new(<<-RUBY).parse
        module M
          class A
            def cleanup(force)
              if force
                delete_file()
              else
                puts_args()
              end
            end
          end
        end

        i = 0
        while i < 3
          fetch_url()
          i += 1
        end

        M::A.new.cleanup(true)
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Error
      summary.tags.should eq Set{RiskTag::DeletesFiles, RiskTag::NetworkEgress}
    end

    it "an undefined constant path is RiskUnresolved, not a crash" do
      interp, _ = make_interp
      setup_risky_sample_fns(interp)
      walker = RiskWalker.new(interp)
      body = Parser.new("Ghost::Nested.method").parse
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Error
      summary.path.first.should contain "unresolved"
    end

    it "a defined module but undefined nested class is RiskUnresolved, not a crash" do
      interp, _ = make_interp
      setup_risky_sample_fns(interp)
      walker = RiskWalker.new(interp)
      body = Parser.new(<<-RUBY).parse
        module M
        end
        M::Ghost.method
      RUBY
      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.severity.should eq Severity::Error
    end

    it "TypeInference resolves M::A.new to KnownType directly (not just through RiskWalker)" do
      interp, _ = make_interp
      interp.eval(<<-RUBY)
        module M
          class A
          end
        end
      RUBY
      inference = TypeInference.new(interp)
      body = Parser.new("M::A.new").parse
      hint = inference.infer_node(body.stmts.first, TypeInference::Env.new)
      hint.should be_a(KnownType)
    end
  end

  describe "RiskWalker: all four risky_example receiver shapes agree" do
    # The four scripts are semantically identical programs (same
    # delete_file/puts_args-behind-an-if, same fetch_url loop) reached
    # through four different receiver shapes. Asserts they all produce
    # the SAME worst-case summary — the point of the whole fix.
    it "top-level def, def self.foo, module-nested def self.foo, and module-nested instance method all agree" do
      interp, _ = make_interp
      setup_risky_sample_fns(interp)
      walker = RiskWalker.new(interp)

      variants = {
        "top-level def" => <<-RUBY,
          def cleanup(force)
            if force
              delete_file()
            else
              puts_args()
            end
          end
          i = 0
          while i < 3
            fetch_url()
            i += 1
          end
          cleanup(true)
        RUBY
        "def self.foo on a class" => <<-RUBY,
          class A
            def self.cleanup(force)
              if force
                delete_file()
              else
                puts_args()
              end
            end
          end
          i = 0
          while i < 3
            fetch_url()
            i += 1
          end
          A.cleanup(true)
        RUBY
        "def self.foo nested in a module" => <<-RUBY,
          module M
            class A
              def self.cleanup(force)
                if force
                  delete_file()
                else
                  puts_args()
                end
              end
            end
          end
          i = 0
          while i < 3
            fetch_url()
            i += 1
          end
          M::A.cleanup(true)
        RUBY
        "instance method nested in a module" => <<-RUBY,
          module M
            class A
              def cleanup(force)
                if force
                  delete_file()
                else
                  puts_args()
                end
              end
            end
          end
          i = 0
          while i < 3
            fetch_url()
            i += 1
          end
          M::A.new.cleanup(true)
        RUBY
      }

      summaries = variants.map do |label, src|
        {label, RiskAggregator.summarize(walker.walk_body(Parser.new(src).parse))}
      end

      summaries.each do |label, summary|
        summary.severity.should eq Severity::Error
        summary.tags.should eq Set{RiskTag::DeletesFiles, RiskTag::NetworkEgress}
      end
    end
  end
end
