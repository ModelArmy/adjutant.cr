require "json"
require "../ruby_class"
require "../diagnostic"
require "../builtins/helpers"
require "../native_call_context"
require "./stream"

module Adjutant
  module Legate
    module Helpers
      # Builds the `Legate` module, once; every Legate submodule nests
      # its classes into the instance returned.
      def self.build_module(interp : Interpreter) : RubyClass
        legate = RubyClass.new("Legate", nil, is_module: true)
        legate.rclass = interp.class_class
        legate
      end

      # Builds a class named `name` nested in `parent`, reachable as
      # `Legate::Foo` through constant lookup, as a script's nested
      # class is: registered in `parent.constants` with `parent` as
      # its lexical parent.
      def self.nest(parent : RubyClass, interp : Interpreter, name : String,
                    superclass : RubyClass? = nil, is_module : Bool = false) : RubyClass
        cls = RubyClass.new(name, superclass, is_module: is_module)
        cls.rclass = interp.class_class
        cls.lexical_parent = parent
        parent.constants[interp.symbols.intern(name).value] = Value.rclass(cls)
        cls
      end

      # The class nested in `parent` as `name`, for a native method
      # that must raise it. Raises InternalError if missing, which
      # means the bootstrap order is wrong.
      def self.fetch(parent : RubyClass, interp : Interpreter, name : String) : RubyClass
        val = parent.constants[interp.symbols.intern(name).value]?
        val.try(&.as_rclass?) || raise InternalError.new("Legate::#{name} not yet bootstrapped when Legate::Helpers.fetch(#{name.inspect}) was called — check bootstrap_legate's ordering")
      end

      # Converts parsed JSON to Values, recursively. Every piece,
      # container or leaf, carries `label`, since decoding reshapes
      # the source text without adding to it; Hash keys don't, being
      # metadata.
      def self.json_to_value(interp : Interpreter, json : ::JSON::Any, label : RiskFlowLabel?) : Value
        case raw = json.raw
        when Nil     then Value.nil_value
        when Bool    then Value.bool(raw)
        when Int64   then Value.int(raw, label)
        when Float64 then Value.float(raw, label)
        when String  then Value.string(raw, label)
        when Array(::JSON::Any)
          Value.new(LabeledArray.new(raw.map { |item| json_to_value(interp, item, label) }, label), label)
        when Hash(String, ::JSON::Any)
          entries = {} of Value => Value
          raw.each { |key, value| entries[Value.string(key)] = json_to_value(interp, value, label) }
          Value.new(LabeledHash.new(entries, label), label)
        else
          Value.nil_value
        end
      end

      # The characters `Dir.glob` treats as wildcards, used only by
      # `fixed_prefix`.
      WILDCARD_CHARS = {'*', '?', '[', '{'}

      # The leading components of a glob pattern that contain no
      # wildcard: `src/**/*.rb` gives `src`, `*.txt` gives `.`. The
      # directory whose grant and sensitivity gate the pattern.
      # Expects `/` separators; call `Path#to_posix` first, since
      # `Dir.glob` wants `/` on every platform.
      def self.fixed_prefix(pattern : String) : String
        kept = [] of String
        pattern.split('/').each do |part|
          break if part.each_char.any? { |char| WILDCARD_CHARS.includes?(char) }
          kept << part
        end
        prefix = kept.join('/')
        prefix.empty? ? "." : prefix
      end

      # Reads keyword `kwarg` with a type check: nil if omitted, the
      # value if the right type, otherwise R036 (`TypeError`) rather
      # than a Crystal cast error. Verbs read their keywords through
      # these rather than calling `as_int` and friends directly.
      def self.checked_int_kwarg(ncc : NativeCallContext, method : String, kwarg : String) : Int64?
        given = ncc.kwargs.try(&.[kwarg]?)
        return unless given
        return given.as_int if given.int?
        raise_kwarg_type_error(ncc, method, kwarg, "Integer", given)
      end

      def self.checked_bool_kwarg(ncc : NativeCallContext, method : String, kwarg : String) : Bool?
        given = ncc.kwargs.try(&.[kwarg]?)
        return unless given
        return given.as_bool if given.bool?
        raise_kwarg_type_error(ncc, method, kwarg, "true or false", given)
      end

      def self.checked_symbol_kwarg(ncc : NativeCallContext, method : String, kwarg : String) : Sym?
        given = ncc.kwargs.try(&.[kwarg]?)
        return unless given
        return given.as_sym if given.symbol?
        raise_kwarg_type_error(ncc, method, kwarg, "Symbol", given)
      end

      # Raises R036 for a keyword of the wrong type, for keywords the
      # `checked_*` readers don't cover (`fetch`'s `headers:` and
      # `body:`).
      def self.raise_kwarg_type_error(ncc : NativeCallContext, method : String, kwarg : String,
                                      expected : String, given : Value) : NoReturn
        ncc.raise_error(
          "R036",
          {"method" => method, "kwarg" => kwarg, "expected" => expected, "class_name" => Builtins.builtin_type_name(given)},
          "TypeError",
        )
      end

      # Raises R039, the positional counterpart of
      # `raise_kwarg_type_error`.
      def self.raise_arg_type_error(ncc : NativeCallContext, method : String, arg : String,
                                    expected : String, given : Value) : NoReturn
        ncc.raise_error(
          "R039",
          {"method" => method, "arg" => arg, "expected" => expected, "class_name" => Builtins.builtin_type_name(given)},
          "TypeError",
        )
      end

      # Writes `data` to `io` for `Legate.write` and `Legate.append`: a
      # String, an Array of Strings, or a Legate stream walked one
      # element at a time, so a stream is never held whole (§4.3).
      # Anything else raises R037. Each piece is recorded against the
      # write budget as it is written, so a large write can exhaust
      # the budget partway. `method` names the verb in errors.
      def self.write_io_data(io : IO, data_val : Value, ncc : NativeCallContext, broker : Broker,
                             eof : RubyClass, method : String) : Int64
        if data_val.string?
          return write_io_piece(io, data_val, ncc, broker, method)
        end

        if arr = data_val.as_array?
          total = 0_i64
          arr.to_a.each { |piece| total += write_io_piece(io, piece, ncc, broker, method) }
          return total
        end

        if (robj = data_val.as_robject?) && robj.is_a?(StreamObject)
          total = 0_i64
          Legate::Stream.walk(robj, ncc, eof) { |piece| total += write_io_piece(io, piece, ncc, broker, method) }
          return total
        end

        ncc.raise_error(
          "R037",
          {"method" => method, "class_name" => Builtins.builtin_type_name(data_val)},
          "TypeError",
        )
      end

      # Writes one element and records it. A non-String raises R038;
      # there is no implicit `to_s`.
      def self.write_io_piece(io : IO, piece : Value, ncc : NativeCallContext, broker : Broker, method : String) : Int64
        unless piece.string?
          ncc.raise_error(
            "R038",
            {"method" => method, "class_name" => Builtins.builtin_type_name(piece)},
            "TypeError",
          )
        end
        bytes = piece.as_string.to_slice
        io.write(bytes)
        broker.budget.record_write(bytes.size.to_i64)
        bytes.size.to_i64
      end
    end
  end
end
