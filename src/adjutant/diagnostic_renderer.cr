require "./diagnostic"
require "./source_map"

module Adjutant
  # Turns a `Diagnostic` into text.
  #
  # Rendering is deliberately separate from the Diagnostic itself.
  # Baking presentation into the raise sites is exactly what the old
  # `"#{message} (line #{line}, col #{column})"` string interpolation
  # did, and it is what made both l10n and alternative output formats
  # impossible without touching every raise site.
  #
  # No colour, by design. The primary reader is an LLM under an agent
  # harness, for which ANSI escapes are noise in a captured log, and
  # carets do not need colour to work. A human reading Markdown output
  # through a renderer gets structure from the Markdown instead.
  class DiagnosticRenderer
    enum Format
      # For LLM consumers and for piping through a Markdown renderer
      # when showing a human.
      Markdown

      # For terminals and logs.
      PlainText
    end

    # Where a reader should report an `I`-series diagnostic.
    #
    # Adjutant is embedded, so this has to be overridable: if an agent
    # harness ships Adjutant, its users should report to whoever ships
    # the harness — they can triage and forward — not to a project the
    # user has never heard of. Defaulting upstream and letting the host
    # change it beats every integrator patching this catalog.
    DEFAULT_REPORT_URL = "https://github.com/ModelArmy/adjutant.cr/issues/new"

    def initialize(@sources : SourceMap? = nil, @report_url : String = DEFAULT_REPORT_URL)
    end

    # `default_filename` fills in a span whose own filename is nil —
    # see `Span`. The caller almost always knows it (the interpreter
    # is evaluating a named file) even when the phase that raised did
    # not.
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

    # nil when no span produced any renderable text at all.
    private def snippet_block(diag : Diagnostic, default_filename : String?) : String?
      parts = diag.spans.compact_map { |span| snippet(span, default_filename) }
      return nil if parts.empty?
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

    # Aligns to a 1-based column. Tabs in source will misalign carets
    # here — real, known, and not worth solving until a script that
    # indents with tabs actually produces a diagnostic.
    private def indent_to(col : Int32) : String
      " " * (col - 1)
    end

    # Markdown fences must be longer than any backtick run inside the
    # block, or the fence closes early and the layout collapses. Script
    # source routinely contains backticks, so this cannot be a fixed
    # three.
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
