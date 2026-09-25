module Adjutant
  # Script source by filename, so a diagnostic can show the offending
  # line. Keyed by filename because `require` evaluates further files,
  # and a diagnostic may point at any of them.
  class SourceMap
    def initialize
      @lines = {} of String => Array(String)
    end

    # Splits into lines once, at registration.
    def register(filename : String, source : String) : Nil
      @lines[filename] = source.lines
    end

    def registered?(filename : String) : Bool
      @lines.has_key?(filename)
    end

    # A 1-based line's text, or nil if the file wasn't registered or
    # the line is out of range, in which case the diagnostic renders
    # without a snippet.
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
