require "json"
require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

module Adjutant
  module Legate
    # `Legate::Response` (LEGATE.md §5.5), built only by
    # `Legate.fetch`. Header values carry the label and `body` keeps
    # its own; status, URL and header names are metadata and don't.
    # `json` carries the body's label onto every decoded piece.
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

        # Parses a String body as JSON into Hashes and Arrays. Not a
        # general JSON API for scripts.
        Builtins.define(cls, interp, "json") do |args, _blk, ncc|
          body = args.first.as_robject.ivars[body_sym]
          str = body.as_string? || ncc.raise_error_class("Legate::Response#json — body is not a String", malformed)
          begin
            Helpers.json_to_value(interp, ::JSON.parse(str), body.label)
          rescue ex : ::JSON::ParseException
            ncc.raise_error_class("Legate::Response#json — invalid JSON: #{ex.message}", malformed)
          end
        end

        # Raises `Legate::Transport` unless `ok?`; otherwise returns
        # self (§5.5).
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

      # Header names are downcased (§5.5). §5.5 also calls the headers
      # frozen, but Adjutant has no freezing, so they are an ordinary
      # mutable Hash. `body` is passed through with its own label;
      # `label` goes on the header values and the object.
      def self.build(interp : Interpreter, rclass : RubyClass, status : Int32,
                     headers : Hash(String, String), body : Value, url : String,
                     label : RiskFlowLabel? = nil) : Value
        obj = RubyObject.new(rclass)
        obj.ivars[interp.symbols.intern("__status").value] = Value.int(status)
        entries = {} of Value => Value
        headers.each { |key, value| entries[Value.string(key.downcase)] = Value.string(value, label) }
        obj.ivars[interp.symbols.intern("__headers").value] = Value.new(LabeledHash.new(entries, label), label)
        obj.ivars[interp.symbols.intern("__body").value] = body
        obj.ivars[interp.symbols.intern("__url").value] = Value.string(url)
        Value.robject(obj, RiskFlowLabel.join(body.label, label))
      end
    end
  end
end
