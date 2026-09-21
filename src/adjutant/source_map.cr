module Adjutant
  # Retains script source, keyed by filename, so a diagnostic can be
  # rendered with the offending line under it.
  #
  # Nothing needed to change about how source is READ: `Lexer` already
  # slurps the whole IO into a String in its constructor (a documented
  # choice — random access for peek/backtrack/lexeme slicing). The
  # source has always existed in memory at parse time; it was simply
  # dropped on the floor once tokens were produced, so by the time
  # anything failed there was nothing left to quote.
  #
  # Keyed by filename rather than held as a single string because
  # `Interpreter#require_module` evals further files: a diagnostic's
  # filename is not always the top-level script's, so a single-source
  # field would quote the wrong file's line — worse than quoting none,
  # since it looks authoritative.
  class SourceMap
    def initialize
      @lines = {} of String => Array(String)
    end

    # Stores lines eagerly rather than the whole string: rendering
    # always wants a specific line, and splitting once beats splitting
    # per diagnostic.
    def register(filename : String, source : String) : Nil
      @lines[filename] = source.lines
    end

    def registered?(filename : String) : Bool
      @lines.has_key?(filename)
    end

    # The source text of a 1-based line, or nil if that file was never
    # registered or the line is out of range. Nil is normal, not
    # exceptional — a host can render diagnostics from a script it
    # never registered, and gets a snippet-less report rather than a
    # crash.
    def line(filename : String?, line : Int32) : String?
      return unless filename
      lines = @lines[filename]?
      return unless lines
      return unless 1 <= line <= lines.size
      lines[line - 1]
    end

    def clear : Nil
      @lines.clear
    end
  end
end
