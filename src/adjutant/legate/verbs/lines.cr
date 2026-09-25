require "../broker"
require "../stream"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.lines(path, max_line: 1_048_576, scrub: true) ->
      # Legate::Lines` (LEGATE.md §4.2): a stream of the file's lines,
      # read in chunks. Authorization and existence are checked when
      # `Legate.lines` is called; `max_line` and encoding failures can
      # only surface while iterating (§4.2).
      module Lines
        KWARG_NAMES      = Set{"max_line", "scrub"}
        DEFAULT_MAX_LINE = 1_048_576
        READ_CHUNK_SIZE  =    65_536

        # Lines are split on raw bytes, so the scrub check sees one
        # line's original bytes.
        NEWLINE = 0x0A_u8

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          not_found = Helpers.fetch(legate, interp, "NotFound")
          too_many = Helpers.fetch(legate, interp, "TooMany")
          too_large = Helpers.fetch(legate, interp, "TooLarge")
          malformed = Helpers.fetch(legate, interp, "Malformed")
          lines_cls = Helpers.nest(legate, interp, "Lines")
          stream_module = Helpers.fetch(legate, interp, "Stream")
          lines_cls.include_module(stream_module)

          legate.define_native_singleton_method(
            interp.symbols.intern("lines").value,
            RiskProfile.new(effects: Set{Effect::ReadsFiles}), # complements declare_sensitivity — see stat.cr's own comment
            KWARG_NAMES,
          ) do |args, _blk, ncc|
            # Keywords are validated before authorizing.
            max_line = max_line_of(ncc)
            scrub = scrub_flag(ncc)

            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string
            label = str_val.label

            # A missing path inside a granted root is
            # `Legate::NotFound`, not a denial. The label joins the path
            # argument's with the one policy gives the path.
            label = RiskFlowLabel.join(label, broker.authorize_read(raw, ncc, allow_missing: true))

            unless File.info?(raw)
              ncc.raise_error_class("#{raw} not found", not_found)
            end

            # The stream cap is checked before the handle is opened; see
            # `Broker#check_stream_capacity!`. A file removed since the
            # existence check fails in `File.open` as a Crystal error.
            broker.check_stream_capacity!(ncc, too_many)

            io = File.open(raw, "rb")
            iterator = LineIterator.new(io, max_line, scrub, malformed, too_large, raw, label, broker, ncc)
            # The verb registers the source, not the iterator's
            # constructor; see bytes.cr.
            broker.register_source(iterator)
            Value.robject(StreamObject.new(lines_cls, iterator))
          end
        end

        private def self.max_line_of(ncc : NativeCallContext) : Int32
          given = Helpers.checked_int_kwarg(ncc, "Legate.lines", "max_line")
          n = given ? given.to_i32 : DEFAULT_MAX_LINE
          n > 0 ? n : DEFAULT_MAX_LINE
        end

        private def self.scrub_flag(ncc : NativeCallContext) : Bool
          given = Helpers.checked_bool_kwarg(ncc, "Legate.lines", "scrub")
          given.nil? ? true : given
        end

        # Owns the open file for one walk and closes it at exhaustion,
        # so a later terminal gets `Legate::EOF`. Reads raw byte chunks
        # rather than using `IO#gets(limit)`, which truncates an
        # over-long line where §4.2 requires `Legate::TooLarge`.
        class LineIterator
          include ::Iterator(Value)
          include Closable

          # `ncc` is the one `Legate.lines` was called with, since
          # `Iterator#next` can't receive the walking terminal's. So an
          # error raised during iteration reports the `Legate.lines`
          # line, not the terminal's.
          def initialize(@io : File, @max_line : Int32, @scrub : Bool, @malformed : RubyClass,
                         @too_large : RubyClass, @path : String, @label : RiskFlowLabel?, @broker : Broker,
                         @ncc : NativeCallContext)
            @pending = ::Bytes.empty
            @io_done = false       # true once the underlying IO itself hit EOF (0-byte read)
            @done = false          # true once there is neither a pending partial line nor more IO to read
            @source_closed = false # true once the handle is shut, whoever shut it
          end

          def next
            return stop if @done

            loop do
              if newline_at = @pending.index(NEWLINE)
                # One chunk can bring in a whole line already past
                # `max_line`, so the cap is checked here as well as below.
                if newline_at > @max_line
                  raise_too_large(newline_at)
                end
                line = @pending[0, newline_at]
                @pending = @pending[(newline_at + 1)..]
                return build_line(line)
              end

              # No newline yet: the cap is checked before pulling more,
              # so a file with no newline fails at `max_line` bytes
              # rather than after reading it all (§4.2).
              if @pending.size > @max_line
                raise_too_large(@pending.size)
              end

              if @io_done
                # Exhausted without a final newline: what's pending is
                # the last line, as in Ruby's `each_line`.
                close_source
                return @pending.empty? ? stop : build_line(@pending)
              end

              pull_more
            end
          end

          # Idempotent. Separate from `@done`: the handle closes one
          # pull before the last line, when the file has no final
          # newline.
          def close_source : Nil
            return if @source_closed
            @source_closed = true
            @done = true
            @io.close
            @broker.open_sources.release(self)
          end

          # Reads one chunk into `@pending`, recording it against the
          # read budget as it arrives.
          private def pull_more : Nil
            buf = ::Bytes.new(READ_CHUNK_SIZE)
            n = @io.read(buf)
            if n == 0
              @io_done = true
              return
            end
            @broker.budget.record_read(n.to_i64)
            @pending = concat(@pending, buf[0, n])
          end

          # `a` followed by `b`, in a new buffer. `Slice#+` offsets a
          # slice rather than joining two.
          private def concat(a : ::Bytes, b : ::Bytes) : ::Bytes
            return b if a.empty?
            combined = ::Bytes.new(a.size + b.size)
            combined.copy_from(a)
            (combined + a.size).copy_from(b)
            combined
          end

          # One line's Value. `String.new(Bytes)` doesn't validate, so
          # invalid UTF-8 is scrubbed to U+FFFD, or raises
          # `Legate::Malformed` with `scrub: false`.
          private def build_line(raw_line : ::Bytes) : Value
            raw_str = String.new(raw_line)
            return Value.string(raw_str, @label) if raw_str.valid_encoding?

            if @scrub
              Value.string(raw_str.scrub, @label)
            else
              @ncc.raise_error_class("#{@path}: invalid UTF-8 byte sequence in a line (scrub: false)", @malformed)
            end
          end

          private def raise_too_large(size : Int32) : NoReturn
            @ncc.raise_error_class("#{@path} has a line over #{@max_line} bytes (max_line) with no newline yet seen — use Legate.bytes(path) to stream raw chunks instead.", @too_large)
          end
        end
      end
    end
  end
end
