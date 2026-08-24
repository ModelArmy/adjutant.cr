require "json"
require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

module Adjutant
  module Legate
    # `Legate::Response` — LEGATE.md §5.5. Broker-manufactured only —
    # see Stat's own comment for why (no public constructor; plain
    # `RubyObject` + `__`-prefixed ivars).
    module Response
      def self.bootstrap(interp : Interpreter, legate : RubyClass) : Nil
        cls = Helpers.nest(legate, interp, "Response")
        status_sym = interp.symbols.intern("__status").value
        headers_sym = interp.symbols.intern("__headers").value
        body_sym = interp.symbols.intern("__body").value
        url_sym = interp.symbols.intern("__url").value
        transport = Helpers.fetch(legate, interp, "Transport")
        malformed = Helpers.fetch(legate, interp, "Malformed")

        Builtins.define(cls, interp, "status") { |args| args.first.as_robject.ivars[status_sym] }
        Builtins.define(cls, interp, "ok?") { |args| Value.bool(ok?(args.first.as_robject.ivars[status_sym].as_int)) }
        Builtins.define(cls, interp, "headers") { |args| args.first.as_robject.ivars[headers_sym] }
        Builtins.define(cls, interp, "body") { |args| args.first.as_robject.ivars[body_sym] }
        Builtins.define(cls, interp, "url") { |args| args.first.as_robject.ivars[url_sym] }

        # Body -> Hash | Array, via Crystal's own JSON parser as an
        # implementation detail — this does NOT expose a general
        # `JSON` module to scripts (LEGATE.md's "pure core... is
        # specified separately" — a real script-facing `JSON.parse`/
        # `.generate` is separate, not-yet-scoped work). Only String
        # bodies are parseable today; a `Legate::Bytes`-stream body
        # (§6, not built until step 3/5) raising here too is the
        # right default once that exists — nothing to do yet.
        Builtins.define(cls, interp, "json") do |args, _blk, ncc|
          body = args.first.as_robject.ivars[body_sym]
          str = body.as_string? || ncc.raise_error_class("Legate::Response#json — body is not a String", malformed)
          begin
            json_to_value(interp, ::JSON.parse(str))
          rescue ex : ::JSON::ParseException
            ncc.raise_error_class("Legate::Response#json — invalid JSON: #{ex.message}", malformed)
          end
        end

        # Raises Legate::Transport unless ok?, else returns self — the
        # common case where a script genuinely wants a non-2xx to be
        # fatal, without forcing that choice on every caller
        # (LEGATE.md §5.5's own stated reason for this method).
        Builtins.define(cls, interp, "raise!") do |args, _blk, ncc|
          status = args.first.as_robject.ivars[status_sym].as_int
          unless ok?(status)
            ncc.raise_error_class("Legate::Response#raise! — HTTP #{status}, not 2xx", transport)
          end
          args.first
        end
      end

      private def self.ok?(status : Int64) : Bool
        status >= 200 && status <= 299
      end

      # `headers` keys are downcased at construction — LEGATE.md §5.5:
      # "downcased keys, frozen" (the "frozen" half is aspirational —
      # Adjutant has no real freeze/frozen? mechanism at all yet, see
      # DEVELOPMENT.md's dup/clone entry — so this is an ordinary
      # mutable Hash Value like any other; nothing currently stops a
      # script from mutating it, matching every other "frozen" claim
      # in LEGATE.md today). `body` is whatever Value the broker
      # already has (a String today; a `Legate::Bytes` stream once
      # streams exist — §6, not built yet).
      def self.build(interp : Interpreter, rclass : RubyClass, status : Int32,
                     headers : Hash(String, String), body : Value, url : String) : Value
        obj = RubyObject.new(rclass)
        obj.ivars[interp.symbols.intern("__status").value] = Value.int(status)
        entries = {} of Value => Value
        headers.each { |key, value| entries[Value.string(key.downcase)] = Value.string(value) }
        obj.ivars[interp.symbols.intern("__headers").value] = Value.new(LabeledHash.new(entries), nil)
        obj.ivars[interp.symbols.intern("__body").value] = body
        obj.ivars[interp.symbols.intern("__url").value] = Value.string(url)
        Value.robject(obj)
      end

      # Crystal's `JSON::Any` -> Adjutant `Value`, recursively.
      # `JSON::Any#raw` is the underlying Crystal value; each variant
      # maps onto the ordinary Value constructor for that shape —
      # Hash keys are always JSON strings, matching how Adjutant's
      # own Hash already uses String-keyed Value pairs elsewhere.
      private def self.json_to_value(interp : Interpreter, json : ::JSON::Any) : Value
        case raw = json.raw
        when Nil     then Value.nil_value
        when Bool    then Value.bool(raw)
        when Int64   then Value.int(raw)
        when Float64 then Value.float(raw)
        when String  then Value.string(raw)
        when Array(::JSON::Any)
          Value.new(LabeledArray.new(raw.map { |item| json_to_value(interp, item) }), nil)
        when Hash(String, ::JSON::Any)
          entries = {} of Value => Value
          raw.each { |key, value| entries[Value.string(key)] = json_to_value(interp, value) }
          Value.new(LabeledHash.new(entries), nil)
        else
          Value.nil_value
        end
      end
    end
  end
end
