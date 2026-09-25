require "./error_catalog"

module Adjutant
  # The host passed Adjutant something it can't accept (an H code).
  # An ArgumentError, so a host's `rescue ArgumentError` catches it.
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

  # An internal invariant broke outside compilation and execution,
  # such as in `RiskAggregator.summarize`. Other I codes ride on
  # CompileError or RuntimeError.
  class InternalError < Exception
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

  # The host drove Adjutant into a state it can't serve, such as
  # running a VM twice (an H code). No argument was wrong, so this
  # isn't a HostArgumentError.
  class HostStateError < Exception
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

  # A place in a source file a diagnostic points at. Precision varies
  # by phase: the lexer and parser know the line, column and length;
  # the compiler knows line and column, and a length only when the
  # raise site works one out; the VM knows only the line. Without a
  # `column` a renderer draws no carets; without a `length`, one.
  # A nil `filename` means the unit being compiled, which the
  # Compiler isn't told; the renderer supplies it.
  struct Span
    getter filename : String?
    getter line : Int32
    getter column : Int32?
    getter length : Int32?

    # The note under the caret; the fuller explanation is the
    # catalog's `why`.
    getter label : String?

    def initialize(@line, @column = nil, @length = nil, @filename = nil, @label = nil)
    end

    def resolve_filename(default : String?) : String?
      @filename || default
    end
  end

  # A structured error report: a code, spans and substitutions, with
  # all wording from `ErrorCatalog` at render time, so translating
  # Adjutant means a second catalog. Separate from the error objects a
  # script can rescue, which follow Ruby: a Diagnostic is for the
  # reader.
  struct Diagnostic
    getter code : String

    # Nil for a diagnostic about no place in a script, as for an H
    # code raised before any script exists, or one where the running
    # script isn't at fault.
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

    # True for the I series: a fault in Adjutant, not the script.
    # Renderers show a report footer instead of a help line, since
    # there's nothing in the script to fix.
    def internal? : Bool
      code.starts_with?("I")
    end

    # Every span, primary first; empty when there's no location.
    def spans : Array(Span)
      if span = primary
        [span] + secondary
      else
        secondary
      end
    end

    # One line with the code, for messages and logs.
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
