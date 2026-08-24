require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

module Adjutant
  module Legate
    # `Legate::Path` — LEGATE.md §5.1. Pure: constructing, joining, and
    # inspecting a path needs no grant; only passing one to a verb
    # does (the broker's job, not this file's).
    #
    # Represented as a PLAIN `RubyObject` with two `__`-prefixed ivars
    # (`__parts` : Array<String>, `__absolute` : Bool) — the same
    # convention `Range` already uses (`__min`/`__max`/`__exclusive`,
    # `vm.cr`'s `range_values_equal?`) — rather than a custom
    # `PathObject < RubyObject` subclass carrying real Crystal-only
    # fields the way `TimeObject`/`RegexpObject`/`MatchDataObject` do.
    # Deliberate: nothing about a Path's state needs a type `ivars`
    # can't hold (an Array<String> and a Bool are both ordinary
    # Values), and staying plain-`RubyObject` sidesteps the `dup`/
    # `clone` gap SCOPE.md's Must Fix now tracks entirely — a plain
    # `RubyObject`'s `ivars` are shallow-copied correctly today; only
    # subclasses with state OUTSIDE `ivars` are exposed to that bug.
    module Path
      # `Legate::Path.new("some/dir/file.log")` — the ONLY public
      # constructor (LEGATE.md §5.1, amended to `.new` rather than the
      # `Path[...]` bracket-literal form the spec originally showed —
      # `ClassName[...]` bracket dispatch has no support for a class
      # receiver in Adjutant today; see the design conversation this
      # amendment came out of). A native singleton `new`, not a
      # generic allocate-then-initialize path — same reasoning
      # `Regexp.new`/`Exception.new` already establish for a builtin
      # needing real construction-time work (here: parsing/splitting
      # the string) rather than a bare ivars-only allocation.
      def self.bootstrap(interp : Interpreter, legate : RubyClass) : Nil
        cls = Helpers.nest(legate, interp, "Path")
        parts_sym = interp.symbols.intern("__parts").value
        absolute_sym = interp.symbols.intern("__absolute").value
        malformed = Helpers.fetch(legate, interp, "Malformed")

        Builtins.define_singleton(cls, interp, "new") do |args|
          str = (args[1]? || Value.nil_value).as_string
          build(args.first.as_rclass, str, parts_sym, absolute_sym)
        end

        Builtins.define(cls, interp, "/") do |args, _blk, ncc|
          join(args, ncc, parts_sym, absolute_sym, malformed)
        end

        Builtins.define(cls, interp, "parent") do |args|
          obj = args.first.as_robject
          parts = obj.ivars[parts_sym].as_array.to_a.map(&.as_string)
          absolute = obj.ivars[absolute_sym].as_bool
          make(obj.rclass, parts[0...-1]? || [] of String, absolute, parts_sym, absolute_sym)
        end

        Builtins.define(cls, interp, "basename") do |args|
          Value.string(basename_of(args, parts_sym))
        end

        Builtins.define(cls, interp, "ext") do |args|
          Value.string(ext_of(basename_of(args, parts_sym)))
        end

        Builtins.define(cls, interp, "stem") do |args|
          b = basename_of(args, parts_sym)
          e = ext_of(b)
          Value.string(e.empty? ? b : b[0...(b.size - e.size)])
        end

        Builtins.define(cls, interp, "parts") do |args|
          args.first.as_robject.ivars[parts_sym]
        end

        Builtins.define(cls, interp, "absolute?") do |args|
          args.first.as_robject.ivars[absolute_sym]
        end

        # A Path is considered `under?` itself too (inclusive) — the
        # useful shape for a boundary check like `path.under?(root)`,
        # which should accept `path == root` as satisfying the
        # boundary rather than requiring a STRICT descendant.
        Builtins.define(cls, interp, "under?") do |args|
          under(args, parts_sym, absolute_sym)
        end

        Builtins.define(cls, interp, "to_s") do |args|
          obj = args.first.as_robject
          parts = obj.ivars[parts_sym].as_array.to_a.map(&.as_string)
          absolute = obj.ivars[absolute_sym].as_bool
          Value.string(render(parts, absolute))
        end
      end

      # `Legate::Path#/`'s own body — extracted out of `bootstrap`
      # purely for ameba's CyclomaticComplexity budget (the `if`/
      # `elsif`/`&&` chain deciding how to interpret `other` pushed
      # the enclosing method over the limit); no behavior change from
      # having it inline.
      private def self.join(args : Array(Value), ncc : NativeCallContext,
                            parts_sym : Int32, absolute_sym : Int32, malformed : RubyClass) : Value
        self_obj = args.first.as_robject
        self_parts = self_obj.ivars[parts_sym].as_array.to_a.map(&.as_string)
        self_absolute = self_obj.ivars[absolute_sym].as_bool

        other = args[1]? || Value.nil_value
        other_robj = other.as_robject?
        other_str = other_robj.try(&.ivars[parts_sym]?) ? nil : other.as_string?
        other_parts, other_absolute = if other_str
                                        split_path(other_str)
                                      elsif other_robj && other_robj.ivars[parts_sym]?
                                        {other_robj.ivars[parts_sym].as_array.to_a.map(&.as_string), other_robj.ivars[absolute_sym].as_bool}
                                      else
                                        {[] of String, false}
                                      end

        if other_absolute
          ncc.raise_error_class("Legate::Path#/ — #{other} is absolute, not a relative segment to join", malformed)
        end
        if other_parts.any? { |part| part == ".." }
          ncc.raise_error_class("Legate::Path#/ — #{other} contains \"..\", which / never allows (construction-time traversal guard, LEGATE.md §5.1)", malformed)
        end

        make(self_obj.rclass, self_parts + other_parts, self_absolute, parts_sym, absolute_sym)
      end

      # `Legate::Path#under?`'s own body — same complexity-budget
      # reasoning as `join` above.
      private def self.under(args : Array(Value), parts_sym : Int32, absolute_sym : Int32) : Value
        self_obj = args.first.as_robject
        self_parts = self_obj.ivars[parts_sym].as_array.to_a.map(&.as_string)
        self_absolute = self_obj.ivars[absolute_sym].as_bool

        other = args[1]? || Value.nil_value
        other_robj = other.as_robject?
        return Value.bool(false) unless other_robj && other_robj.ivars[parts_sym]?

        other_parts = other_robj.ivars[parts_sym].as_array.to_a.map(&.as_string)
        other_absolute = other_robj.ivars[absolute_sym].as_bool
        Value.bool(self_absolute == other_absolute && self_parts.first(other_parts.size) == other_parts)
      end

      # Splits a raw path string into (parts, absolute?) — leading
      # `/` marks absolute; consecutive/trailing `/` collapse away via
      # the empty-segment reject, matching ordinary path-splitting
      # semantics (`"a//b/".split("/")` style).
      private def self.split_path(str : String) : {Array(String), Bool}
        absolute = str.starts_with?('/')
        parts = str.split('/').reject(&.empty?)
        {parts, absolute}
      end

      private def self.build(rclass : RubyClass, str : String, parts_sym : Int32, absolute_sym : Int32) : Value
        parts, absolute = split_path(str)
        make(rclass, parts, absolute, parts_sym, absolute_sym)
      end

      private def self.make(rclass : RubyClass, parts : Array(String), absolute : Bool,
                            parts_sym : Int32, absolute_sym : Int32) : Value
        obj = RubyObject.new(rclass)
        obj.ivars[parts_sym] = Value.new(LabeledArray.new(parts.map { |part| Value.string(part) }), nil)
        obj.ivars[absolute_sym] = Value.bool(absolute)
        Value.robject(obj)
      end

      # PUBLIC Crystal-level constructor — `Legate::Path.new(str)`
      # (above) is the SCRIPT-facing entry point; this is the
      # CRYSTAL-facing one, for code that already has a raw path
      # string and needs a real `Legate::Path` Value without going
      # through `eval`. Two real callers: this session's own specs
      # (constructing fixture Paths for Entry/Match without a nested
      # `interp.eval` call from inside an already-running native
      # function — a reentrancy question not worth risking untested),
      # and — the reason this exists as PUBLIC API rather than
      # spec-only scaffolding — the future broker, which LEGATE.md §8
      # requires to "convert every path argument to Legate::Path at
      # the verb boundary": a verb receiving a raw `String` argument
      # needs exactly this, called from Crystal, not a script-level
      # round-trip.
      def self.from_string(interp : Interpreter, rclass : RubyClass, str : String) : Value
        build(rclass, str, interp.symbols.intern("__parts").value, interp.symbols.intern("__absolute").value)
      end

      private def self.basename_of(args : Array(Value), parts_sym : Int32) : String
        parts = args.first.as_robject.ivars[parts_sym].as_array.to_a
        parts.last?.try(&.as_string) || ""
      end

      # Real Ruby's File.extname semantics, close enough for Legate's
      # purposes: a dotfile with no other `.` (".hidden") has no
      # extension; a trailing-only dot ("file.") counts as its own
      # extension "."; everything else is the substring from the
      # LAST `.` onward.
      private def self.ext_of(basename : String) : String
        idx = basename.rindex('.')
        return "" unless idx
        return "" if idx == 0
        basename[idx..]
      end

      private def self.render(parts : Array(String), absolute : Bool) : String
        return "/" if absolute && parts.empty?
        return "." if !absolute && parts.empty?
        (absolute ? "/" : "") + parts.join("/")
      end
    end
  end
end
