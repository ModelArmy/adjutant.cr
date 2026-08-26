require "csv"
require "json"
require "../broker"
require "../stream"
require "../exceptions"
require "../helpers"
require "../../native_call_context"
require "./lines"

module Adjutant
  module Legate
    module Verbs
      # `Legate.records(path, format:, headers: true) -> Legate::Records`
      # — LEGATE.md §4.2. Third and last of the read-only streaming
      # slice, after `bytes`/`lines` — genuinely two separate parsers
      # under one verb, not a thin wrapper over either:
      #
      # - `:jsonl` is built directly on `Lines::LineIterator` (this
      #   file's `require "./lines"`) — one JSON value per line, so
      #   the line-splitting/cap/scrub work `lines.cr` already proved
      #   out is exactly what's needed underneath; only the
      #   line->parsed-JSON step is new here.
      # - `:csv` is Crystal's OWN stdlib `CSV::Parser`, per the
      #   handoff's own flag: not used anywhere else in this codebase,
      #   so its exact signature/behavior is asserted from the
      #   published API docs, not independently confirmed against a
      #   live toolchain — the single most likely spot in this file to
      #   need a correction once `ops build`/`ops test` actually run
      #   it (see the CSV-specific comments below for the two
      #   sharpest edges: `next_row`'s `nil`-at-EOF contract and
      #   whether `CSV::Error` is the right rescue class for malformed
      #   input).
      #
      # A `:jsonl` record's top-level JSON object keys are SYMBOLIZED
      # (`it[:spam]`, matching LEGATE.md §6.5's own worked example
      # verbatim) — a deliberate, judgment-call divergence from
      # `Legate::Response#json`'s general JSON decode (STRING keys,
      # real-JSON-semantics faithful), made specifically so `:jsonl`
      # and `:csv` (whose column headers are the natural source of a
      # record's field names) present the SAME "one row, symbol-keyed
      # fields" shape to a script, rather than one being String-keyed
      # and the other Symbol-keyed for what a script author would
      # reasonably expect to be the same kind of value. Only the
      # TOP-LEVEL keys of an object-shaped jsonl line are symbolized —
      # a nested Hash value inside a record keeps ordinary String
      # keys via the shared `Helpers.json_to_value`, since those are
      # nested DATA, not the record's own column/field names.
      module Records
        KWARG_NAMES = Set{"format", "headers"}

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          not_found = Helpers.fetch(legate, interp, "NotFound")
          malformed = Helpers.fetch(legate, interp, "Malformed")
          too_large = Helpers.fetch(legate, interp, "TooLarge")
          records_cls = Helpers.nest(legate, interp, "Records")
          stream_module = Helpers.fetch(legate, interp, "Stream")
          records_cls.include_module(stream_module)

          legate.define_native_singleton_method(
            interp.symbols.intern("records").value,
            RiskProfile.new(tags: Set{RiskTag::ReadsFiles}),
            KWARG_NAMES,
          ) do |args, _blk, ncc|
            # `format:` validated BEFORE `authorize_read` deliberately
            # — a bad `format:` is a pure call-site programmer error,
            # unrelated to the path or the grant; authorizing (and
            # audit-logging) a read attempt that's about to fail on
            # its own kwarg regardless would be a spurious log entry.
            format = format_of(ncc)

            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string
            label = str_val.label

            broker.authorize_read(raw, ncc, allow_missing: true)
            unless File.info?(raw)
              ncc.raise_error_class("#{raw} not found", not_found)
            end

            headers_flag = headers_flag_of(ncc)
            io = File.open(raw, "rb")

            iterator =
              case format
              when "jsonl"
                # `scrub: true`, fixed (not a kwarg records exposes)
                # — invalid UTF-8 bytes get replaced with U+FFFD
                # BEFORE the JSON parse step runs, so a raw encoding
                # problem doesn't crash the parse; the JSON parser
                # itself then still catches genuinely invalid JSON
                # (`Malformed`, below) on the (now valid-UTF-8)
                # result. `Lines::DEFAULT_MAX_LINE` reused as-is —
                # records doesn't expose its own `max_line:` kwarg
                # (not in LEGATE.md's signature), but a pathologically
                # long single JSONL line still needs SOME cap, and
                # this is the one `lines.cr` already established.
                line_iter = Lines::LineIterator.new(
                  io, Lines::DEFAULT_MAX_LINE, true, malformed, too_large, raw, label, broker, ncc,
                )
                JsonlIterator.new(line_iter, malformed, ncc, interp, label)
              when "csv"
                counting_io = BudgetCountingIO.new(io, broker)
                parser = ::CSV::Parser.new(counting_io)
                CsvIterator.new(parser, io, interp, headers_flag, label, ncc, malformed, raw)
              else
                raise InternalError.new("Legate.records: unreachable — format_of already validated \"#{format}\"")
              end

            Value.robject(StreamObject.new(records_cls, iterator))
          end
        end

        private def self.format_of(ncc : NativeCallContext) : String
          given = ncc.kwargs.try(&.["format"]?)
          sym = given.try(&.as_sym?)
          # `case`, not `return name if name == "jsonl" || ...` — that
          # shape doesn't type-narrow `name` (`String?`) down to
          # `String` in Crystal the way `is_a?`/truthiness checks do
          # (`==` isn't a narrowing operator here), so the method's
          # declared `String` return type didn't actually hold. Caught
          # by `ops build`, not by inspection.
          case sym.try(&.name)
          when "jsonl" then return "jsonl"
          when "csv"   then return "csv"
          end

          repr = if given.nil?
                   "(missing)"
                 elsif sym
                   ":#{sym.name}"
                 else
                   "(not a Symbol)"
                 end
          ncc.raise_error("R034", {"format" => repr}, "ArgumentError")
        end

        private def self.headers_flag_of(ncc : NativeCallContext) : Bool
          given = ncc.kwargs.try(&.["headers"]?)
          given ? given.as_bool : true
        end

        # Wraps a `Lines::LineIterator` (one raw text line per pull,
        # already scrubbed/cap-checked) and JSON-parses each — the
        # `:jsonl` half of this verb. Composition, not inheritance:
        # every line-splitting/budget/cap concern stays entirely
        # inside `Lines::LineIterator`, unmodified; this class's own
        # job is exactly one step — text line in, parsed `Value` out.
        class JsonlIterator
          include ::Iterator(Value)

          def initialize(@lines : Lines::LineIterator, @malformed : RubyClass,
                         @ncc : NativeCallContext, @interp : Interpreter, @label : RiskFlowLabel?)
          end

          def next
            line_val = @lines.next
            return stop if line_val.is_a?(Iterator::Stop)

            text = line_val.as_string
            begin
              parsed = ::JSON.parse(text)
            rescue ex : ::JSON::ParseException
              @ncc.raise_error_class("invalid JSON on a jsonl line: #{ex.message}", @malformed)
            end
            symbolize_top_level(parsed)
          end

          # Converts via the shared `Helpers.json_to_value`, then — if
          # (and only if) the top-level shape is a JSON object —
          # rebuilds just that one Hash's KEYS as Symbols. See this
          # module's own top comment for why only the top level, not
          # nested values.
          private def symbolize_top_level(parsed : ::JSON::Any) : Value
            value = Helpers.json_to_value(@interp, parsed, @label)
            hash = value.as_hash?
            return value unless hash

            entries = {} of Value => Value
            hash.each do |key, v|
              sym = @interp.symbols.intern(key.as_string)
              entries[Value.symbol(sym)] = v
            end
            Value.new(LabeledHash.new(entries, @label), @label)
          end
        end

        # Thin `IO` wrapper whose only job is recording bytes pulled
        # through it against the run's shared read budget, PER
        # UNDERLYING `#read` CALL — `CSV::Parser` does its own
        # internal buffering/read-ahead directly against whatever
        # `IO` it's given (unlike `Lines::LineIterator`, which does
        # its own chunked reads by hand and can record explicitly),
        # so this is the seam available to hook the same "streaming
        # accounting, not read-everything-then-account" requirement
        # `bytes.cr`/`lines.cr` both already satisfy. Read-only:
        # `#write` is never reachable through a `CSV::Parser`
        # (parsing only reads), so raising there rather than
        # implementing real write-through is deliberate, not an
        # oversight.
        class BudgetCountingIO < IO
          def initialize(@io : File, @broker : Broker)
          end

          def read(slice : ::Bytes) : Int32
            n = @io.read(slice)
            @broker.budget.record_read(n.to_i64) if n > 0
            n
          end

          def write(slice : ::Bytes) : Nil
            raise NotImplementedError.new("Legate::Records' BudgetCountingIO is read-only")
          end
        end

        # The `:csv` half. NOT independently verified against a live
        # toolchain (see this module's own top comment) — two specific
        # assumptions about `CSV::Parser`, either of which `ops build`/
        # `ops test` could correct:
        #   1. `#next_row : Array(String)?` returns `nil` at EOF
        #      (rather than raising, or returning an empty Array).
        #   2. `::CSV::Error` is the right base class to rescue for
        #      malformed CSV input (unterminated quote, etc.) — named
        #      by analogy with `::JSON::ParseException` above, not
        #      confirmed against the actual `csv` stdlib source.
        class CsvIterator
          include ::Iterator(Value)

          def initialize(@parser : ::CSV::Parser, @io : File, @interp : Interpreter, @headers_flag : Bool,
                         @label : RiskFlowLabel?, @ncc : NativeCallContext, @malformed : RubyClass, @path : String)
            @header_syms = nil.as(Array(Sym)?)
            @headers_read = false
            @done = false
          end

          def next
            return stop if @done

            if @headers_flag && !@headers_read
              @headers_read = true
              first = pull_row
              if first.nil?
                return finish
              end
              @header_syms = first.map { |name| @interp.symbols.intern(name) }
            end

            row = pull_row
            return finish if row.nil?

            header_syms = @header_syms
            if @headers_flag && header_syms
              if row.size != header_syms.size
                @ncc.raise_error_class(
                  "#{@path}: CSV row has #{row.size} column(s), expected #{header_syms.size} (headers)", @malformed,
                )
              end
              entries = {} of Value => Value
              header_syms.each_with_index { |sym, i| entries[Value.symbol(sym)] = Value.string(row[i], @label) }
              Value.new(LabeledHash.new(entries, @label), @label)
            else
              Value.new(LabeledArray.new(row.map { |v| Value.string(v, @label) }, @label), @label)
            end
          end

          private def pull_row : Array(String)?
            @parser.next_row
          rescue ex : ::CSV::Error
            @ncc.raise_error_class("#{@path}: malformed CSV: #{ex.message}", @malformed)
          end

          private def finish : Iterator::Stop
            @done = true
            @io.close
            stop
          end
        end
      end
    end
  end
end
