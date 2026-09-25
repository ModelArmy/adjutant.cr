require "../broker"
require "../stream"
require "../chunk"
require "../exceptions"
require "../helpers"
require "../../native_call_context"

module Adjutant
  module Legate
    module Verbs
      # `Legate.bytes(path, chunk: 65_536) -> Legate::Bytes`
      # (LEGATE.md §4.2): a stream of Legate::Chunks. Authorization and
      # existence are checked when `Legate.bytes` is called (§4.2); the
      # file is read lazily, one chunk per pull.
      #
      # This module's name hides Crystal's top-level `Bytes`, so the
      # byte-slice type is written `::Bytes` throughout.
      module Bytes
        KWARG_NAMES        = Set{"chunk"}
        DEFAULT_CHUNK_SIZE = 65_536

        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          not_found = Helpers.fetch(legate, interp, "NotFound")
          too_many = Helpers.fetch(legate, interp, "TooMany")
          bytes_cls = Helpers.nest(legate, interp, "Bytes")
          chunk_cls = Helpers.fetch(legate, interp, "Chunk")
          stream_module = Helpers.fetch(legate, interp, "Stream")
          bytes_cls.include_module(stream_module)

          legate.define_native_singleton_method(
            interp.symbols.intern("bytes").value,
            RiskProfile.new(effects: Set{Effect::ReadsFiles}), # complements declare_sensitivity — see stat.cr's own comment
            KWARG_NAMES,
          ) do |args, _blk, ncc|
            # `chunk:` is validated before authorizing.
            chunk_size = chunk_size_of(ncc)

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

            # A file removed since the existence check fails in
            # `File.open` as a Crystal error, not `NotFound`: other open
            # failures, such as permissions, aren't a missing file. The
            # stream cap is checked before opening, so a refusal leaves
            # no handle.
            broker.check_stream_capacity!(ncc, too_many)

            io = File.open(raw, "rb")
            iterator = ChunkIterator.new(io, chunk_size, chunk_cls, label, broker)
            # Registered by the verb rather than the iterator's
            # constructor, so the object is complete before the run
            # holds it.
            #
            broker.register_source(iterator)
            Value.robject(StreamObject.new(bytes_cls, iterator))
          end
        end

        private def self.chunk_size_of(ncc : NativeCallContext) : Int32
          given = Helpers.checked_int_kwarg(ncc, "Legate.bytes", "chunk")
          n = given ? given.to_i32 : DEFAULT_CHUNK_SIZE
          n > 0 ? n : DEFAULT_CHUNK_SIZE
        end

        # Owns the open file for one walk and closes it when a read
        # returns 0, so a later terminal gets `Legate::EOF`. Each chunk
        # is recorded against the read budget as it is pulled, so a
        # large file exhausts `total_read` partway. A walk halted by
        # `first(n)` or an exception leaves the file open for
        # `OpenSources` to close at the end of the run.
        class ChunkIterator
          include ::Iterator(Value)
          include Closable

          def initialize(@io : File, @chunk_size : Int32, @chunk_cls : RubyClass,
                         @label : RiskFlowLabel?, @broker : Broker)
            @done = false
          end

          def next
            return stop if @done
            buf = ::Bytes.new(@chunk_size)
            n = @io.read(buf)
            if n == 0
              close_source
              return stop
            end
            @broker.budget.record_read(n.to_i64)
            Legate::Chunk.build(@chunk_cls, buf[0, n], @label)
          end

          # Idempotent, as `Closable` requires: exhaustion and the
          # end-of-run teardown can both reach it. `@done` keeps `#next`
          # from reading a closed handle.
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
