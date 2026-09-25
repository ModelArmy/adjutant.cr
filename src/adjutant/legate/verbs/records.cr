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
      # `Legate.records(path, format:, headers: true) ->
      # Legate::Records` (LEGATE.md §4.2): two parsers under one verb.
      # `:jsonl` parses each line from `Lines::LineIterator` as JSON;
      # `:csv` uses Crystal's `CSV::Parser`.
      #
      # A `:jsonl` object's top-level keys are Symbols (`it[:spam]`, as
      # §6.5 shows), so a record has the same shape in either format;
      # nested Hashes keep String keys, as `Response#json` gives.
      module Records
        KWARG_NAMES = Set{"format", "headers"}

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          not_found = Helpers.fetch(legate, interp, "NotFound")
          too_many = Helpers.fetch(legate, interp, "TooMany")
          malformed = Helpers.fetch(legate, interp, "Malformed")
          too_large = Helpers.fetch(legate, interp, "TooLarge")
          records_cls = Helpers.nest(legate, interp, "Records")
          stream_module = Helpers.fetch(legate, interp, "Stream")
          records_cls.include_module(stream_module)

          legate.define_native_singleton_method(
            interp.symbols.intern("records").value,
            RiskProfile.new(effects: Set{Effect::ReadsFiles}),
            KWARG_NAMES,
          ) do |args, _blk, ncc|
            # `format:` is validated before authorizing, so a bad
            # keyword costs no audit record.
            format = format_of(ncc)

            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string
            label = str_val.label

            # The label joins the path argument's with the policy's.
            label = RiskFlowLabel.join(label, broker.authorize_read(raw, ncc, allow_missing: true))
            unless File.info?(raw)
              ncc.raise_error_class("#{raw} not found", not_found)
            end

            headers_flag = headers_flag_of(ncc)
            # The stream cap is checked before the handle is opened.
            broker.check_stream_capacity!(ncc, too_many)

            io = File.open(raw, "rb")

            iterator =
              case format
              when "jsonl"
                # Always scrubbed, so an encoding error doesn't reach the
                # JSON parser, and capped at `Lines::DEFAULT_MAX_LINE`;
                # `records` has neither keyword.
                line_iter = Lines::LineIterator.new(
                  io, Lines::DEFAULT_MAX_LINE, true, malformed, too_large, raw, label, broker, ncc,
                )
                # The line iterator owns the handle, so it is what's
                # registered, not the JSONL wrapper.
                broker.register_source(line_iter)
                JsonlIterator.new(line_iter, malformed, ncc, interp, label)
              when "csv"
                counting_io = BudgetCountingIO.new(io, broker)
                parser = ::CSV::Parser.new(counting_io)
                csv_iter = CsvIterator.new(parser, io, interp, headers_flag, label, ncc, malformed, raw, broker)
                # The CSV iterator owns the handle.
                broker.register_source(csv_iter)
                csv_iter
              else
                raise InternalError.new("Legate.records: unreachable — format_of already validated \"#{format}\"")
              end

            Value.robject(StreamObject.new(records_cls, iterator))
          end
        end

        private def self.format_of(ncc : NativeCallContext) : String
          given = ncc.kwargs.try(&.["format"]?)
          sym = given.try(&.as_sym?)
          # `case` narrows `String?` to `String`; `==` doesn't.
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
          given = Helpers.checked_bool_kwarg(ncc, "Legate.records", "headers")
          given.nil? ? true : given
        end

        # The `:jsonl` parser: a `Lines::LineIterator` for the lines,
        # which does the splitting, capping and budget accounting, and a
        # JSON parse of each.
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

          # The parsed line as a Value, with a top-level object's keys
          # as Symbols.
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

        # A read-only IO that records every underlying `read` against
        # the read budget, since `CSV::Parser` reads ahead on its own.
        # `write` raises.
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

        # The `:csv` parser. `next_row` returns nil at the end, and
        # malformed input raises `CSV::MalformedCSVError`, a
        # `CSV::Error`. There is no per-row size cap: a quoted field
        # can grow until the read budget stops it.
        class CsvIterator
          include ::Iterator(Value)
          include Closable

          def initialize(@parser : ::CSV::Parser, @io : File, @interp : Interpreter, @headers_flag : Bool,
                         @label : RiskFlowLabel?, @ncc : NativeCallContext, @malformed : RubyClass, @path : String,
                         @broker : Broker)
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
            close_source
            stop
          end

          # Idempotent. `@done` suffices: nothing is buffered after the
          # handle closes.
          def close_source : Nil
            return if @done
            @done = true
            @io.close
            @broker.open_sources.release(self)
          end
        end
      end
    end
  end
end
