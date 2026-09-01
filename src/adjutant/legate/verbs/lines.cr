require "../broker"
require "../stream"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.lines(path, max_line: 1_048_576, scrub: true) ->
      # Legate::Lines` — LEGATE.md §4.2. Second `Legate::Stream`-backed
      # verb, built directly on `bytes.cr`'s now-proven "custom
      # `Iterator(Value)` owning an open file handle, closing on
      # physical exhaustion" pattern — the new work here is entirely
      # the line-splitting/cap/scrub layer sitting on top of the same
      # chunked-read shape, not a new streaming mechanism.
      #
      # Eager on authority, same as `bytes` (§4.2's "these verbs raise
      # NotFound and Denied eagerly, at construction, not on first
      # iteration"): the grant/existence check happens the moment
      # `Legate.lines(...)` is called; `max_line`/`scrub` failures are
      # necessarily lazy (§4.2's own text — "Parse and cap failures
      # necessarily raise during iteration"), since they depend on
      # bytes not yet read.
      module Lines
        KWARG_NAMES      = Set{"max_line", "scrub"}
        DEFAULT_MAX_LINE = 1_048_576
        READ_CHUNK_SIZE  =    65_536

        # Raw byte value of `"\n"` — the iterator below works on
        # `::Bytes`, not `String`, until a complete line is isolated
        # (scrub/Malformed detection needs the ORIGINAL bytes of just
        # that one line, not the whole file — see `LineIterator#next`).
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
            # `max_line`/`scrub` validated FIRST — SCOPE.md's "kwarg-
            # validation ordering inconsistent across the read-verb
            # slice" entry (added 2026-08-27) — same reasoning as
            # `read.cr`'s identical retrofit.
            max_line = max_line_of(ncc)
            scrub = scrub_flag(ncc)

            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string
            label = str_val.label

            # `allow_missing: true` then an explicit existence check
            # below — same §2.3-flavoured reasoning as `read`/`bytes`:
            # a missing path under a granted root is recoverable
            # `NotFound`, not a fatal `Denied`.
            #
            # `RiskFlowLabel.join` — see `stat.cr`'s own comment.
            label = RiskFlowLabel.join(label, broker.authorize_read(raw, ncc, allow_missing: true))

            unless File.info?(raw)
              ncc.raise_error_class("#{raw} not found", not_found)
            end

            # Same small, accepted TOCTOU-class race as `bytes.cr`'s
            # own `File.open` call — the file could vanish between
            # the `File.info?` check above and here; left to propagate
            # as a raw Crystal exception rather than guessed at and
            # remapped to a Legate error tier (see that file's own
            # comment for the full reasoning, unchanged here).
            # See `bytes.cr` for why the cap is checked before the
            # handle is opened rather than at registration.
            broker.check_stream_capacity!(ncc, too_many)

            io = File.open(raw, "rb")
            iterator = LineIterator.new(io, max_line, scrub, malformed, too_large, raw, label, broker, ncc)
            # See `bytes.cr`'s identical call for why registration
            # happens in the verb rather than the constructor.
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

        # Owns the open `File` handle for the lifetime of one stream
        # walk, exactly like `bytes.cr`'s `ChunkIterator` — closes it
        # the moment the source is physically exhausted, so any
        # further terminal sees `Legate::EOF` via `Stream`'s own
        # single-pass machinery, not a dangling handle.
        #
        # Reads in fixed-size RAW BYTE chunks (`READ_CHUNK_SIZE`, same
        # size as `bytes.cr`'s own default) rather than delegating to
        # `IO#gets` — `IO#gets(limit)` TRUNCATES a too-long line
        # instead of raising, which can't produce §4.2's required
        # `Legate::TooLarge`, and reading raw bytes (not text) keeps a
        # not-yet-newline-terminated line's `scrub`/`Malformed` check
        # working on the SAME bytes `read.cr`'s own per-file version
        # already established, just scoped to one line instead of one
        # file.
        class LineIterator
          include ::Iterator(Value)
          include Closable

          # `ncc` here is the ONE that constructed this stream (the
          # original `Legate.lines(...)` call) — captured because
          # `::Iterator(Value)#next`'s fixed signature has nowhere to
          # receive `stream.cr`'s `walk` loop's own fresh, per-terminal
          # ncc (see that file's `walk`, which pulls this iterator from
          # inside `each`/`to_a`'s own live call but has no way to pass
          # it down through a bare `#next`). Live judgment call, not
          # independently verified against a real diagnostic
          # inspection: `raise_error_class` only needs a filename/line
          # for DIAGNOSTIC display and a RubyClass to build the error
          # object from (see `vm.cr`'s own `raise_native_error_class`)
          # — using the construction call's filename/line means a
          # `TooLarge`/`Malformed` raised three `.select`/`.map` calls
          # and one `.each` later still reports where `Legate.lines`
          # was CALLED, not the terminal that was walking when the bad
          # byte was hit. Functionally correct and script-catchable
          # either way (the error CLASS and MESSAGE are what a script
          # actually rescues on); only the diagnostic line number is
          # arguably suboptimal. Worth revisiting if that turns out to
          # matter in practice once `ops test` can show real output.
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
                # Cap check belongs HERE too, not only in the no-
                # newline branch below — a single `pull_more` can (and
                # typically does, for any file under ~64 KiB) bring in
                # a newline that's already well past `max_line` in one
                # shot, bypassing the "no newline yet" branch
                # entirely. First draft missed this: it only ever
                # caught a too-long line that spanned MULTIPLE reads,
                # not one sitting fully inside a single chunk — caught
                # by `ops test`, not by inspection.
                if newline_at > @max_line
                  raise_too_large(newline_at)
                end
                line = @pending[0, newline_at]
                @pending = @pending[(newline_at + 1)..]
                return build_line(line)
              end

              # No newline in what's buffered yet — check the cap
              # BEFORE pulling more, so a pathological no-newline file
              # (§4.2's own "one-terabyte file containing no newline
              # is a single line" example) raises as soon as the
              # buffered-so-far size crosses `max_line`, not only once
              # the whole file has been read into memory.
              if @pending.size > @max_line
                raise_too_large(@pending.size)
              end

              if @io_done
                # Physically exhausted with no trailing newline —
                # `@pending` (possibly empty) is the final line, same
                # as Ruby's own `each_line` behavior on a file missing
                # a trailing "\n".
                close_source
                return @pending.empty? ? stop : build_line(@pending)
              end

              pull_more
            end
          end

          # Idempotent — see `bytes.cr`'s `ChunkIterator#close_source`.
          #
          # A SEPARATE `@source_closed` flag rather than reusing
          # `@done`: this iterator closes the handle while still
          # holding a final unterminated line in `@pending` (a file
          # with no trailing newline), so the two states are genuinely
          # distinct — "the handle is shut" happens one pull before
          # "there is nothing left to yield."
          def close_source : Nil
            return if @source_closed
            @source_closed = true
            @done = true
            @io.close
            @broker.open_sources.release(self)
          end

          # Reads one more chunk from `@io`, appends it to `@pending`,
          # and records the read against the run's `total_read`
          # budget PER CHUNK as it's pulled — same reasoning as
          # `bytes.cr`'s own `ChunkIterator#next` (a huge file
          # streaming through must hit budget exhaustion partway, not
          # only once fully buffered).
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

          # `::Bytes` (`Slice(UInt8)`) has no `#+` concatenation of
          # its own — `Slice#+` is POINTER-OFFSET arithmetic (`slice +
          # n` returns a view starting `n` bytes in, not two slices
          # joined), a mismatch caught here rather than at compile
          # time only because there's no local toolchain to catch it
          # first. Built via `Bytes.new` + two `#copy_from` calls
          # instead — NOT independently verified against a live
          # toolchain; if `ops build` shows a different real API for
          # this (Crystal may have a more direct helper), this method
          # is the one to revisit, not the call site above.
          private def concat(a : ::Bytes, b : ::Bytes) : ::Bytes
            return b if a.empty?
            combined = ::Bytes.new(a.size + b.size)
            combined.copy_from(a)
            (combined + a.size).copy_from(b)
            combined
          end

          # Builds the `Value` for one complete line's raw bytes.
          #
          # CORRECTED from the first draft, which assumed (matching a
          # same-shaped, equally unverified comment on `read.cr`'s own
          # `read_content`) that `String.new(Bytes)` either substitutes
          # invalid UTF-8 with U+FFFD or raises. Neither is true: `ops
          # test` showed it does NEITHER — it wraps the raw bytes as a
          # `String` completely unchecked, invalid sequences and all.
          # The actual validating/scrubbing API is `String#valid_
          # encoding?` + `String#scrub` (replaces invalid sequences
          # with U+FFFD, Crystal's own analogue of Ruby's `String#
          # scrub`), used below. `read.cr` likely has this exact same
          # bug — flagged separately, out of scope for this verb's own
          # fix.
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
