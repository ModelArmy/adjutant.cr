require "../broker"
require "../stream"
require "../chunk"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.bytes(path, chunk: 65_536) -> Legate::Bytes` —
      # LEGATE.md §4.2. The FIRST real `Legate::Stream`-backed verb
      # (`Stream` itself has existed since step 3, proven only via a
      # throwaway `TestStream` in specs until now) — proves out the
      # "custom `Iterator(Value)` owning an open file handle, closing
      # on exhaustion" pattern on the SIMPLEST possible case (fixed-
      # size binary chunks, no text/encoding concerns) before `lines`
      # builds the same pattern with a line-cap/scrub layer on top,
      # and `records` builds real JSONL/CSV parsing on top of THAT.
      #
      # Eager on authority (§4.2's own text: "these verbs raise
      # NotFound and Denied eagerly, at CONSTRUCTION") — unlike
      # `read`'s single call that does everything at once, a stream
      # verb's authorization+existence check happens the moment
      # `Legate.bytes(...)` is CALLED, but the actual file reads (and
      # per-chunk budget accounting) happen lazily, one chunk at a
      # time, as the script walks the returned stream.
      #
      # NAMING NOTE: this module is named `Bytes`, matching the
      # established 1:1 verb-name-to-module-name convention (Stat,
      # Read, List) — but that COLLIDES with Crystal's own top-level
      # `Bytes` (`= Slice(UInt8)`) inside this module's own body,
      # since Crystal's constant lookup resolves a bare `Bytes` to
      # THIS module first. Every reference to the real byte-slice type
      # below is explicitly `::Bytes` for exactly this reason — same
      # fix pattern already applied to `Grants`/`Path`'s own `::Path`
      # qualification earlier this session.
      module Bytes
        KWARG_NAMES        = Set{"chunk"}
        DEFAULT_CHUNK_SIZE = 65_536

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          not_found = Helpers.fetch(legate, interp, "NotFound")
          bytes_cls = Helpers.nest(legate, interp, "Bytes")
          chunk_cls = Helpers.fetch(legate, interp, "Chunk")
          stream_module = Helpers.fetch(legate, interp, "Stream")
          bytes_cls.include_module(stream_module)

          legate.define_native_singleton_method(
            interp.symbols.intern("bytes").value,
            RiskProfile.new(tags: Set{RiskTag::ReadsFiles}), # complements declare_sensitivity — see stat.cr's own comment
            KWARG_NAMES,
          ) do |args, _blk, ncc|
            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string
            label = str_val.label

            # `allow_missing: true` then an explicit existence check
            # below — same §2.3-flavoured reasoning as `stat`/`read`:
            # a missing path under a granted root is recoverable
            # `NotFound`, not a fatal `Denied`; only a path outside
            # every granted root is a real denial.
            #
            # `RiskFlowLabel.join` — see `stat.cr`'s own comment.
            label = RiskFlowLabel.join(label, broker.authorize_read(raw, ncc, allow_missing: true))

            unless File.info?(raw)
              ncc.raise_error_class("#{raw} not found", not_found)
            end

            chunk_size = chunk_size_of(ncc)
            # Small, accepted TOCTOU-class race, same family §8.1
            # already normalizes for this codebase: the file could
            # vanish between the `File.info?` check above and this
            # `File.open` call. Left to propagate as a raw, unhandled
            # Crystal exception rather than caught and remapped to
            # `Legate::NotFound` — this specific window is narrow
            # enough, and the alternative (wrapping every possible
            # `File.open` failure mode in a guess about which Legate
            # error tier it belongs to) risks miscategorizing a
            # DIFFERENT failure (e.g. a permissions error) as
            # `NotFound` when it isn't.
            io = File.open(raw, "rb")
            Value.robject(StreamObject.new(bytes_cls, ChunkIterator.new(io, chunk_size, chunk_cls, label, broker)))
          end
        end

        private def self.chunk_size_of(ncc : NativeCallContext) : Int32
          given = ncc.kwargs.try(&.["chunk"]?)
          n = given ? given.as_int.to_i32 : DEFAULT_CHUNK_SIZE
          n > 0 ? n : DEFAULT_CHUNK_SIZE
        end

        # Owns the open `File` handle for the LIFETIME of one stream
        # walk — closes it the moment the source is physically
        # exhausted (`IO#read` returning 0), matching
        # `Legate::Stream`'s own single-pass semantics (stream.cr)
        # exactly: once THIS iterator hits `Stop`, `Legate::EOF` on
        # any further terminal is what a script sees, not a dangling
        # open file handle.
        #
        # `broker.budget.record_read(n)` is called PER CHUNK, as it's
        # pulled — not once at construction like `read`'s single
        # `record_read(info.size)` call — so a script streaming a huge
        # file hits `total_read` budget exhaustion (a fatal
        # `Legate::FatalSignal`, propagating straight out of `next`
        # through `Stream`'s own `walk` loop) partway through, which
        # is the whole point of a per-run budget existing at all —
        # §4.2's single eager `broker.authorize_read` call at
        # construction only covers the STATIC grant/policy check, not
        # budget accounting, which is necessarily progressive for a
        # stream of unknown total size.
        class ChunkIterator
          include ::Iterator(Value)

          def initialize(@io : File, @chunk_size : Int32, @chunk_cls : RubyClass,
                         @label : RiskFlowLabel?, @broker : Broker)
            @done = false
          end

          def next
            return stop if @done
            buf = ::Bytes.new(@chunk_size)
            n = @io.read(buf)
            if n == 0
              @io.close
              @done = true
              return stop
            end
            @broker.budget.record_read(n.to_i64)
            Legate::Chunk.build(@chunk_cls, buf[0, n], @label)
          end
        end
      end
    end
  end
end
