require "./diagnostic"
require "./source_map"

module Adjutant
  # Turns a Diagnostic into text, Markdown or plain. No colour: the
  # main reader is an LLM reading a captured log, where ANSI escapes
  # are noise.
  class DiagnosticRenderer
    enum Format
      # For LLMs, and for a Markdown renderer showing a human.
      Markdown

      # For terminals and logs.
      PlainText
    end

    # Where to report an I-series diagnostic. A host should point this
    # at its own support channel (`Interpreter#report_url`).
    DEFAULT_REPORT_URL = "https://github.com/ModelArmy/adjutant.cr/issues/new"

    def initialize(@sources : SourceMap? = nil, @report_url : String = DEFAULT_REPORT_URL)
    end

    # `default_filename` fills in a span with no filename; see Span.
    def render(diag : Diagnostic, format : Format = Format::Markdown,
               default_filename : String? = nil) : String
      case format
      when Format::PlainText
        render_plain(diag, default_filename)
      else
        render_markdown(diag, default_filename)
      end
    end

    private def render_markdown(diag : Diagnostic, default_filename : String?) : String
      String.build do |io|
        io << "**error[" << diag.code << "]: " << diag.summary << "**\n"
        if block = snippet_block(diag, default_filename)
          fence = fence_for(block)
          io << '\n' << fence << "text\n" << block << '\n' << fence << '\n'
        end
        if why = diag.why
          io << "\n**Why:** " << why << '\n'
        end
        if help = diag.help
          io << "\n**Help:** " << help << '\n'
        end
        if diag.internal?
          io << "\n**This is a bug in Adjutant, not in your script.** "
          io << "Nothing above needs fixing on your end. Please copy this "
          io << "entire report and file it at " << @report_url << '\n'
        end
      end
    end

    private def render_plain(diag : Diagnostic, default_filename : String?) : String
      String.build do |io|
        io << "error[" << diag.code << "]: " << diag.summary << '\n'
        if block = snippet_block(diag, default_filename)
          io << block << '\n'
        end
        if why = diag.why
          io << "why:  " << why << '\n'
        end
        if help = diag.help
          io << "help: " << help << '\n'
        end
        if diag.internal?
          io << "\nThis is a bug in Adjutant, not in your script. Nothing\n"
          io << "above needs fixing on your end. Please copy this entire\n"
          io << "report and file it at:\n"
          io << "  " << @report_url << '\n'
        end
      end
    end

    # Nil when no span produced any text.
    private def snippet_block(diag : Diagnostic, default_filename : String?) : String?
      parts = diag.spans.compact_map { |span| snippet(span, default_filename) }
      return if parts.empty?
      parts.join("\n")
    end

    private def snippet(span : Span, default_filename : String?) : String?
      filename = span.resolve_filename(default_filename)
      source = @sources.try(&.line(filename, span.line))

      String.build do |io|
        io << location(filename, span)
        if source
          io << '\n'
          write_source_lines(io, span, source)
        end
      end
    end

    private def location(filename : String?, span : Span) : String
      String.build do |io|
        io << (filename || "<unknown>") << ':' << span.line
        if col = span.column
          io << ':' << col
        end
      end
    end

    # The `4 | def foo(&blk)` row, plus the caret row beneath it when
    # a column is known.
    private def write_source_lines(io : IO, span : Span, source : String) : Nil
      gutter = span.line.to_s
      pad = " " * gutter.size

      io << gutter << " | " << source
      return unless col = span.column

      io << '\n' << pad << " | " << indent_to(col) << ("^" * (span.length || 1))
      if label = span.label
        io << '\n' << pad << " | " << indent_to(col) << label
      end
    end

    # Spaces to a 1-based column. A tab in the source line misaligns
    # the carets.
    private def indent_to(col : Int32) : String
      " " * (col - 1)
    end

    # A fence longer than any backtick run in the block, since source
    # often contains backticks.
    private def fence_for(body : String) : String
      longest = 0
      body.scan(/`+/) do |match|
        size = match[0].size
        longest = size if size > longest
      end
      "`" * Math.max(3, longest + 1)
    end
  end
end
