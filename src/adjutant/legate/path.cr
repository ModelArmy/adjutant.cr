require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

module Adjutant
  module Legate
    # `Legate::Path` (LEGATE.md §5.1). Pure: building, joining and
    # inspecting a path needs no grant; passing one to a verb does.
    # A plain RubyObject with two ivars, `__parts` (an Array of
    # Strings) and `__absolute` (a Bool), as Range keeps its state.
    #
    # Labels follow the rule that extracted text carries its source's
    # label and derived facts don't: `__parts` and every String a
    # method returns (`basename`, `ext`, `stem`, `to_s`) carry the
    # Path's label; `__absolute`, `absolute?` and `under?` don't. `/`
    # joins both operands' labels.
    module Path
      # Registers Legate::Path with its native singleton `new`, the
      # only script-facing constructor, which parses the string.
      def self.bootstrap(interp : Interpreter, legate : RubyClass) : Nil
        cls = Helpers.nest(legate, interp, "Path")
        parts_sym = interp.symbols.intern("__parts").value
        absolute_sym = interp.symbols.intern("__absolute").value
        malformed = Helpers.fetch(legate, interp, "Malformed")

        Builtins.define_singleton(cls, interp, "new") do |args|
          first = args[1]? || Value.nil_value
          build(args.first.as_rclass, first.as_string, parts_sym, absolute_sym, first.label)
        end

        Builtins.define(cls, interp, "/") do |args, _blk, ncc|
          join(args, ncc, parts_sym, absolute_sym, malformed)
        end

        Builtins.define(cls, interp, "parent") do |args|
          obj = args.first.as_robject
          parts = obj.ivars[parts_sym].as_array.to_a.map(&.as_string)
          absolute = obj.ivars[absolute_sym].as_bool
          make(obj.rclass, parts[0...-1]? || [] of String, absolute, parts_sym, absolute_sym, args.first.label)
        end

        Builtins.define(cls, interp, "basename") do |args|
          Value.string(basename_of(args, parts_sym), args.first.label)
        end

        Builtins.define(cls, interp, "ext") do |args|
          Value.string(ext_of(basename_of(args, parts_sym)), args.first.label)
        end

        Builtins.define(cls, interp, "stem") do |args|
          b = basename_of(args, parts_sym)
          e = ext_of(b)
          Value.string(e.empty? ? b : b[0...(b.size - e.size)], args.first.label)
        end

        Builtins.define(cls, interp, "parts") do |args|
          args.first.as_robject.ivars[parts_sym]
        end

        # A derived fact, so unlabelled.
        Builtins.define(cls, interp, "absolute?") do |args|
          args.first.as_robject.ivars[absolute_sym]
        end

        # Inclusive: a path is `under?` itself. Compares components
        # lexically without resolving `..` or `.`, so
        # `/work/../etc` is `under?` `/work`; not a containment check.
        # Unlabelled, as a derived fact.
        Builtins.define(cls, interp, "under?") do |args|
          under(args, parts_sym, absolute_sym)
        end

        Builtins.define(cls, interp, "to_s") do |args|
          obj = args.first.as_robject
          parts = obj.ivars[parts_sym].as_array.to_a.map(&.as_string)
          absolute = obj.ivars[absolute_sym].as_bool
          Value.string(render(parts, absolute), args.first.label)
        end
      end

      # The body of `Path#/`. The result's label joins both
      # operands'.
      private def self.join(args : Array(Value), ncc : NativeCallContext,
                            parts_sym : Int32, absolute_sym : Int32, malformed : RubyClass) : Value
        self_val = args.first
        self_obj = self_val.as_robject
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

        joined = RiskFlowLabel.join(self_val.label, other.label)
        make(self_obj.rclass, self_parts + other_parts, self_absolute, parts_sym, absolute_sym, joined)
      end

      # The body of `Path#under?`.
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

      # Splits on `/` into components, dropping empty ones, so
      # repeated and trailing slashes vanish. A leading `/` makes the
      # path absolute. `..` and `.` are kept as components.
      private def self.split_path(str : String) : {Array(String), Bool}
        absolute = str.starts_with?('/')
        parts = str.split('/').reject(&.empty?)
        {parts, absolute}
      end

      private def self.build(rclass : RubyClass, str : String, parts_sym : Int32, absolute_sym : Int32,
                             label : RiskFlowLabel? = nil) : Value
        parts, absolute = split_path(str)
        make(rclass, parts, absolute, parts_sym, absolute_sym, label)
      end

      # Builds the object. `label` goes on the Path, on `__parts` and
      # on each part, so every string later returned carries it;
      # `__absolute` is unlabelled.
      private def self.make(rclass : RubyClass, parts : Array(String), absolute : Bool,
                            parts_sym : Int32, absolute_sym : Int32, label : RiskFlowLabel? = nil) : Value
        obj = RubyObject.new(rclass)
        obj.ivars[parts_sym] = Value.new(LabeledArray.new(parts.map { |part| Value.string(part, label) }, label), label)
        obj.ivars[absolute_sym] = Value.bool(absolute)
        Value.robject(obj, label)
      end

      # Builds a Legate::Path from Crystal code, as a verb does when
      # converting a String argument at its boundary (LEGATE.md §8).
      # Pass the argument's `label` so it carries over.
      def self.from_string(interp : Interpreter, rclass : RubyClass, str : String,
                           label : RiskFlowLabel? = nil) : Value
        build(rclass, str, interp.symbols.intern("__parts").value, interp.symbols.intern("__absolute").value, label)
      end

      private def self.basename_of(args : Array(Value), parts_sym : Int32) : String
        parts = args.first.as_robject.ivars[parts_sym].as_array.to_a
        parts.last?.try(&.as_string) || ""
      end

      # Ruby's `File.extname`: from the last `.` onward, except that a
      # dotfile with no other `.` (".hidden") has none, and a trailing
      # dot ("file.") is its own extension.
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
