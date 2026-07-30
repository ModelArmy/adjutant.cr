require "./error_catalog"

module Adjutant
  # The embedding host passed Adjutant something it cannot accept.
  #
  # Subclasses `ArgumentError` because that is what these actually are,
  # so a host's existing `rescue ArgumentError` keeps working. It is
  # deliberately NOT a general "host error" base class: not every way a
  # host can misuse Adjutant is about arguments — an ambiguous policy is
  # about configuration state — and a shared parent would assert
  # something false about half its members. The `H` code classifies the
  # failure; each exception class stays whatever is accurate.
  class HostArgumentError < ArgumentError
    getter diagnostic : Diagnostic?

    def initialize(diagnostic : Diagnostic)
      @diagnostic = diagnostic
      super(diagnostic.to_line)
    end

    def initialize(message : String)
      @diagnostic = nil
      super(message)
    end
  end

  # A location in a source file that a diagnostic points at.
  #
  # `column` and `length` are BOTH optional, and that is deliberate
  # rather than an oversight: position fidelity genuinely differs by
  # phase, and a nullable span is what lets every phase emit a
  # diagnostic today instead of blocking the whole system on the
  # weakest one.
  #
  #   - Lexer/parser have line, column, and a `Token#lexeme` whose size
  #     gives `length` for free — full carets.
  #   - Compiler has `Node#line`/`#column` but no end position, so
  #     `length` is whatever the raise site can work out itself (often
  #     from an identifier's own name), else nil — a single caret.
  #   - VM has `Frame#line` and no column at all — the renderer shows
  #     the source line with no caret row under it.
  #
  # Renderers degrade cleanly: no `column` means no caret row, no
  # `length` means a one-character caret. Improving any phase's
  # fidelity later is then purely additive — it needs no change here
  # and no change to any other phase.
  #
  # `filename` is nullable for a related but distinct reason: the
  # Compiler is never told which file it is compiling (it takes a
  # `Body` and a `SymbolTable`, nothing more). Rather than thread a
  # filename through `Compiler.compile`, `Compiler.new`, and every
  # nested `compile_proc` call for this first slice, nil means "the
  # unit currently being compiled" and whoever renders supplies the
  # name it knows. See `DiagnosticRenderer#render`'s `default_filename`.
  struct Span
    getter filename : String?
    getter line : Int32
    getter column : Int32?
    getter length : Int32?

    # Shown under the caret. Use for the "this specific thing, here"
    # note; the broader explanation belongs in the catalog's `why`.
    getter label : String?

    def initialize(@line, @column = nil, @length = nil, @filename = nil, @label = nil)
    end

    def resolve_filename(default : String?) : String?
      @filename || default
    end
  end

  # A structured, renderable error report.
  #
  # This is DATA, not text. Nothing here is human-readable prose: the
  # code identifies the diagnostic, the spans say where, and `data`
  # supplies substitutions. All wording comes from `ErrorCatalog`,
  # looked up by code at render time.
  #
  # That separation is what makes the l10n scaffolding real rather
  # than aspirational — translating Adjutant means shipping a second
  # catalog, not auditing several hundred interpolated strings spread
  # across the lexer, parser, compiler, and VM.
  #
  # Deliberately NOT connected to the VM's script-visible `error_value`
  # (the objects a script can `rescue`). Those follow Ruby's semantics
  # and must keep doing so under the proper-subset mandate; a
  # Diagnostic is a report ABOUT a failure, aimed at the human or LLM
  # reading the output, not an object the script can catch.
  struct Diagnostic
    getter code : String

    # Nil when the diagnostic isn't about a place in a script at all.
    # The `H` series is why: a host validating a `RiskProfile` at
    # registration time fails before any script exists, and even where
    # one is running, the position would point at script source that is
    # not at fault. A span there would be worse than none — it would
    # aim the reader at innocent code.
    getter primary : Span?

    getter secondary : Array(Span)

    # Substitutions for the catalog template's `{placeholder}`s.
    getter data : Hash(String, String)

    def initialize(@code, @primary = nil, @secondary = [] of Span, @data = {} of String => String)
    end

    def entry : ErrorCatalog::Entry
      ErrorCatalog[code]
    end

    def summary : String
      ErrorCatalog.interpolate(entry.summary, data)
    end

    def why : String?
      if text = entry.why
        ErrorCatalog.interpolate(text, data)
      end
    end

    def help : String?
      if text = entry.help
        ErrorCatalog.interpolate(text, data)
      end
    end

    # True for the `I` series: something went wrong inside Adjutant
    # itself, not in the script.
    #
    # The distinction changes what the reader should DO, which is why
    # it's worth encoding rather than leaving to prose. For every other
    # letter there is something to fix in the script; for this one
    # there is nothing, and a `help` addressed to a script author would
    # be actively misleading — it invites someone to spend time editing
    # code that was never the problem. Renderers append a report
    # footer instead of a help line.
    def internal? : Bool
      code.starts_with?("I")
    end

    # Every span, primary first. Renderers walk this in order. Empty
    # for a diagnostic with no source location at all.
    def spans : Array(Span)
      if span = primary
        [span] + secondary
      else
        secondary
      end
    end

    # One-line form, for contexts with no room to render a snippet
    # (exception messages, logs). Carries the code so the reader can
    # still look the full explanation up.
    def to_line : String
      span = primary
      return "[#{code}] #{summary}" unless span
      pos = String.build do |io|
        io << " (line " << span.line
        if col = span.column
          io << ", col " << col
        end
        io << ")"
      end
      "[#{code}] #{summary}#{pos}"
    end
  end
end
