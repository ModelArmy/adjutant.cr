require "../spec_helper"

module Adjutant
  describe ErrorCatalog do
    it "interpolates placeholders from a diagnostic's data" do
      out = ErrorCatalog.interpolate("a {x} and {y}", {"x" => "1", "y" => "2"})
      out.should eq("a 1 and 2")
    end

    it "leaves an unsupplied placeholder verbatim rather than blanking it" do
      # A visible `{y}` says the diagnostic was built wrong. Emitting
      # an empty string would produce a grammatical sentence that had
      # quietly lost the detail the reader needed.
      out = ErrorCatalog.interpolate("a {x} and {y}", {"x" => "1"})
      out.should eq("a 1 and {y}")
    end

    it "returns a self-describing entry for an unknown code" do
      # The reporting path must not raise: an exception while building
      # an error report replaces a bad message with no message.
      ErrorCatalog["Z999"].summary.should contain("Z999")
    end

    it "reports the placeholders a code actually uses" do
      ErrorCatalog.placeholders("U001").should eq(["method", "param"])
    end
  end

  describe Diagnostic do
    it "draws its wording from the catalog, not the raise site" do
      diag = Diagnostic.new(
        code: "U001",
        primary: Span.new(line: 1, column: 9, length: 4),
        data: {"param" => "blk", "method" => "foo"}
      )
      diag.summary.should contain("`&blk`")
      # `why`/`help` are nilable — the catalog allows a summary-only
      # entry — so they need unwrapping before a String matcher.
      diag.why.not_nil!.should contain("yield")
      diag.help.not_nil!.should contain("foo")
    end

    it "renders a one-line form carrying the code" do
      diag = Diagnostic.new(
        code: "U001",
        primary: Span.new(line: 3, column: 9),
        data: {"param" => "blk", "method" => "foo"}
      )
      diag.to_line.should contain("[U001]")
      diag.to_line.should contain("line 3, col 9")
    end

    it "omits the column from the one-line form when there isn't one" do
      diag = Diagnostic.new(code: "U001", primary: Span.new(line: 3))
      diag.to_line.should contain("line 3")
      diag.to_line.should_not contain("col")
    end
  end

  describe DiagnosticRenderer do
    source = "def foo(&blk)\nend\n"

    make_renderer = -> {
      sources = SourceMap.new
      sources.register("script.rb", source)
      DiagnosticRenderer.new(sources)
    }

    diag = Diagnostic.new(
      code: "U001",
      primary: Span.new(line: 1, column: 9, length: 4, label: "not usable as a value"),
      data: {"param" => "blk", "method" => "foo"}
    )

    it "renders the source line with carets under the offending span" do
      out = make_renderer.call.render(diag, DiagnosticRenderer::Format::PlainText, "script.rb")
      out.should contain("1 | def foo(&blk)")
      # Eight spaces then four carets — under `&blk`, column 9, width 4.
      out.should contain("  |         ^^^^")
    end

    it "falls back to a filename supplied by the caller" do
      # The compiler is never told which file it is compiling, so a
      # span's filename is nil and the renderer resolves it.
      out = make_renderer.call.render(diag, DiagnosticRenderer::Format::PlainText, "script.rb")
      out.should contain("script.rb:1:9")
    end

    it "renders without a snippet when the source was never registered" do
      out = DiagnosticRenderer.new.render(diag, DiagnosticRenderer::Format::PlainText, "script.rb")
      out.should contain("script.rb:1:9")
      out.should_not contain("def foo")
    end

    it "omits the caret row when no column is known" do
      # The VM has line but no column; it must still be able to
      # report, just with less precision.
      line_only = Diagnostic.new(
        code: "U001",
        primary: Span.new(line: 1),
        data: {"param" => "blk", "method" => "foo"}
      )
      out = make_renderer.call.render(line_only, DiagnosticRenderer::Format::PlainText, "script.rb")
      out.should contain("1 | def foo(&blk)")
      out.should_not contain("^")
    end

    it "emits Markdown with a fenced snippet and labelled sections" do
      out = make_renderer.call.render(diag, DiagnosticRenderer::Format::Markdown, "script.rb")
      out.should contain("**error[U001]:")
      out.should contain("```text")
      out.should contain("**Why:**")
      out.should contain("**Help:**")
    end

    it "lengthens the fence past any backtick run in the source" do
      # Script source can contain backticks; a fixed three-backtick
      # fence would close early and collapse the layout.
      sources = SourceMap.new
      sources.register("t.rb", "x = \"```\"\n")
      out = DiagnosticRenderer.new(sources).render(
        Diagnostic.new(code: "U001", primary: Span.new(line: 1, column: 1)),
        DiagnosticRenderer::Format::Markdown,
        "t.rb"
      )
      out.should contain("````text")
    end
  end

  describe SourceMap do
    it "returns nil for an unregistered file or out-of-range line" do
      map = SourceMap.new
      map.register("a.rb", "one\ntwo\n")
      map.line("a.rb", 2).should eq("two")
      map.line("a.rb", 9).should be_nil
      map.line("missing.rb", 1).should be_nil
      map.line(nil, 1).should be_nil
    end
  end

  describe "Interpreter source registration" do
    it "registers source on parse, so a later phase's diagnostic can quote it" do
      # The gap this closes: a host that built an Adjutant::Parser
      # itself got diagnostics with a position but no snippet — the
      # feature silently not working rather than visibly failing.
      interp = Interpreter.new(
        risk_flow_policy: TEST_REJECT_ALL_POLICY,
        on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
      )
      body = interp.parse("def foo(&blk)\nend", "script.rb")
      interp.sources.line("script.rb", 1).should eq("def foo(&blk)")

      # The U001 rejection happens at compile, AFTER parse — the point
      # of registering early is that it is quotable anyway.
      error = expect_raises(CompileError) { interp.eval(body, "script.rb") }
      rendered = interp.render_error(
        error,
        DiagnosticRenderer::Format::PlainText,
        "script.rb"
      )
      rendered.not_nil!.should contain("1 | def foo(&blk)")
      rendered.not_nil!.should contain("^^^^")
    end

    it "returns nil from render_error for an unmigrated raise site" do
      # Lets a host fall back on `message` instead of tracking which
      # raise sites have been converted.
      interp = Interpreter.new(
        risk_flow_policy: TEST_REJECT_ALL_POLICY,
        on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
      )
      legacy = CompileError.new("something old", 1, 1)
      interp.render_error(legacy).should be_nil
    end
  end

  describe "internal diagnostics" do
    internal = Diagnostic.new(
      code: "I001",
      primary: Span.new(line: 1),
      data: {"opcode" => "97"}
    )

    it "is flagged internal by its code letter" do
      internal.internal?.should be_true
      Diagnostic.new(code: "U001", primary: Span.new(line: 1)).internal?.should be_false
    end

    it "tells the reader nothing needs fixing on their end" do
      # The point of the I series: every other letter implies there is
      # something to change in the script, and for these there isn't.
      out = DiagnosticRenderer.new.render(internal, DiagnosticRenderer::Format::PlainText)
      out.should contain("bug in Adjutant")
      out.should contain(DiagnosticRenderer::DEFAULT_REPORT_URL)
    end

    it "carries no help line, only the report footer" do
      ErrorCatalog["I001"].help.should be_nil
    end

    it "points at a host-supplied URL when one is set" do
      # Adjutant is embedded — an integrator's users should report to
      # the integrator, not upstream.
      renderer = DiagnosticRenderer.new(nil, "https://example.test/bugs")
      out = renderer.render(internal, DiagnosticRenderer::Format::PlainText)
      out.should contain("https://example.test/bugs")
      out.should_not contain(DiagnosticRenderer::DEFAULT_REPORT_URL)
    end

    it "is reachable through the interpreter's own property" do
      interp = Interpreter.new(
        risk_flow_policy: TEST_REJECT_ALL_POLICY,
        on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
      )
      interp.report_url.should eq(DiagnosticRenderer::DEFAULT_REPORT_URL)
      interp.report_url = "https://harness.test/report"
      error = CompileError.new(
        Diagnostic.new(code: "I005", primary: Span.new(line: 1), data: {"node" => "Foo"})
      )
      interp.render_error(error, DiagnosticRenderer::Format::PlainText)
        .not_nil!.should contain("https://harness.test/report")
    end
  end

  describe "errors without a diagnostic" do
    # This is the boundary the whole nilable-`diagnostic` design exists
    # for, and the thing most likely to be "tidied away" by someone
    # finishing what looks like an incomplete migration.
    interp = Interpreter.new(
      risk_flow_policy: TEST_REJECT_ALL_POLICY,
      on_risk_flow_decision: TEST_UNEXPECTED_ASK_CALLBACK,
    )

    it "leaves a script's own raise uncoded" do
      # `raise "boom"` is the script author's error, not a failure
      # Adjutant classified. No catalog entry could say anything true
      # about it, so it gets no code.
      error = expect_raises(RuntimeError) { interp.eval(%(raise "boom")) }
      error.diagnostic.should be_nil
      error.message.not_nil!.should contain("boom")
    end

    it "renders as nil so a consumer falls back to the script's wording" do
      error = expect_raises(RuntimeError) { interp.eval(%(raise "boom")) }
      interp.render_error(error).should be_nil
    end

    it "still codes a failure Adjutant itself detected" do
      # The contrast that makes the distinction meaningful.
      error = expect_raises(RuntimeError) { interp.eval("no_such_thing") }
      error.diagnostic.not_nil!.code.should eq("R008")
    end
  end

  describe "host state errors" do
    it "refuses to reuse a VM, without blaming the script" do
      # Fires before any script runs, so no script could rescue it —
      # and a RuntimeError would imply one should.
      symbols = SymbolTable.new
      body = Parser.new("1 + 1", "t.rb").parse
      chunk, locals = Compiler.compile(body, symbols)
      vm = VM.new(symbols)
      vm.run(chunk, "t.rb", locals)
      error = expect_raises(HostStateError) { vm.run(chunk, "t.rb", locals) }
      error.diagnostic.not_nil!.code.should eq("H005")
    end

    it "reports a bare VM's inability to require as the host's wiring" do
      # A VM with no interpreter is a supported configuration — it just
      # cannot resolve modules. That makes this H, not the script's
      # R010.
      symbols = SymbolTable.new
      body = Parser.new(%(require "anything"), "t.rb").parse
      chunk, locals = Compiler.compile(body, symbols)
      error = expect_raises(HostStateError) do
        VM.new(symbols).run(chunk, "t.rb", locals)
      end
      error.diagnostic.not_nil!.code.should eq("H006")
    end

    it "is not a HostArgumentError, since no argument was wrong" do
      # Separate classes for separate problems — a shared parent would
      # assert something false about one of them.
      HostStateError.new("x").is_a?(ArgumentError).should be_false
    end
  end

  describe "internal errors with no natural exception class" do
    it "reports an unhandled risk node with a code and a report footer" do
      # Was a bare `raise`, which surfaced as an untyped Crystal
      # exception: no code, and nothing telling the reader this was
      # ours to fix rather than theirs.
      diag = Diagnostic.new(code: "I007", data: {"node" => "RiskWhatever"})
      diag.internal?.should be_true
      out = DiagnosticRenderer.new.render(diag, DiagnosticRenderer::Format::PlainText)
      out.should contain("I007")
      out.should contain("bug in Adjutant")
    end

    it "uses InternalError, since aggregation is neither compiling nor running" do
      # The letter classifies the failure; the class stays accurate.
      # There is no CompileError or RuntimeError that would be true here.
      error = InternalError.new(Diagnostic.new(code: "I007"))
      error.diagnostic.not_nil!.code.should eq("I007")
      error.is_a?(CompileError).should be_false
    end
  end

  describe "ERRORS.md consistency" do
    # error_catalog.cr is authoritative; ERRORS.md documents it for
    # readers. Two artifacts holding the same facts is exactly the
    # drift this project has been removing from its docs, so the
    # duplication is machine-checked rather than left to convention.
    it "documents every code in the catalog" do
      doc = File.read(File.join(__DIR__, "..", "..", "ERRORS.md"))
      ErrorCatalog.codes.each do |code|
        doc.should contain(code)
      end
    end

    it "documents every placeholder each code uses" do
      doc = File.read(File.join(__DIR__, "..", "..", "ERRORS.md"))
      ErrorCatalog.codes.each do |code|
        ErrorCatalog.placeholders(code).each do |name|
          doc.should contain("`#{name}`")
        end
      end
    end
  end
end
