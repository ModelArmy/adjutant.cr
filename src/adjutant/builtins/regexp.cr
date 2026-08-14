require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "./helpers"

# A Regexp instance's real state: the compiled Crystal `::Regex` plus
# the two Ruby-visible attributes mirrored into ivars for
# `#source`/`#options`. The compiled `::Regex` itself can't live in
# `ivars` — there's no `Value` variant for it, the same reason
# `ScriptProc`'s closure snapshot lives in its own `outer_locals`
# field rather than in `ivars` (see `RubyObject`'s own doc comment) —
# so it gets a real typed field here instead, the exact subclassing
# pattern that comment describes for a builtin with real internal
# state.
module Adjutant
  class RegexpObject < RubyObject
    getter regex : ::Regex

    def initialize(rclass : RubyClass, @regex : ::Regex)
      super(rclass)
    end
  end

  module Builtins
    # Bit values for Regexp::IGNORECASE/MULTILINE/EXTENDED. These match
    # real Ruby's own values as best recalled — NOT independently
    # verified against a live Ruby here (no toolchain in this
    # environment). The mruby fixture only ever compares these
    # symbolically (`Regexp::IGNORECASE | Regexp::MULTILINE`, never a
    # bare literal), so an internal mismatch with real Ruby's numbers
    # wouldn't fail anything in-repo — but flag it if something external
    # ever depends on the literal value.
    IGNORECASE = 1
    EXTENDED   = 2
    MULTILINE  = 4

    # Compiles Adjutant's Ruby-facing flag bitmask into Crystal's own
    # Regex::Options. The one genuinely load-bearing piece here: real
    # Ruby's `^`/`$` ALWAYS match line boundaries — that's not gated by
    # any flag — while PCRE2/Crystal only do that under
    # Regex::Options::MULTILINE. So MULTILINE is passed
    # UNCONDITIONALLY below, regardless of whether the script's own
    # Regexp::MULTILINE bit was set. Ruby's `/m` flag means something
    # different (dot matches newline, PCRE2's DOTALL) and is mapped to
    # DOTALL separately. Getting this backwards would be exactly the
    # "ran, looked plausible, was wrong" bug class this project stays
    # alert for — see the compatibility discussion in the handoff this
    # phase came out of.
    #
    # Crystal's exact Regex::Options member names below (IGNORE_CASE /
    # MULTILINE / DOTALL / EXTENDED) are not independently verified
    # against a toolchain here — no local `crystal` binary to check
    # against. If `ops test` reports an unknown constant, this is the
    # first place to look.
    def self.regex_options(adjutant_flags : Int32) : ::Regex::Options
      opts = ::Regex::Options::MULTILINE # real Ruby's ^/$ semantics, always on
      opts |= ::Regex::Options::IGNORE_CASE if adjutant_flags & IGNORECASE != 0
      opts |= ::Regex::Options::DOTALL if adjutant_flags & MULTILINE != 0
      opts |= ::Regex::Options::EXTENDED if adjutant_flags & EXTENDED != 0
      opts
    end

    # Compiles `pattern` under `adjutant_flags`, raising a real,
    # script-catchable R021 (RegexpError) through `ctx` on an invalid
    # pattern rather than letting Crystal's own Regex::Error escape and
    # get flattened into an opaque internal N001 (see
    # NativeCallContext#raise_error's own doc comment for why that
    # matters). `ctx` is nilable because Op::MakeRegex (a literal,
    # evaluated directly by the VM with no NativeCallContext in scope)
    # needs the same compile step as `Regexp.new` — see
    # VM#make_regexp_object.
    def self.compile_regex(pattern : String, adjutant_flags : Int32,
                           ctx : NativeCallContext?) : ::Regex
      ::Regex.new(pattern, regex_options(adjutant_flags))
    rescue ex : ::Exception
      reason = ex.message || "invalid pattern"
      if ctx
        ctx.raise_error("R021", {"reason" => reason}, error_class: "RegexpError")
      else
        raise ex
      end
    end

    def self.bootstrap_regexp(interp : Interpreter) : RubyClass
      cls = RubyClass.new("Regexp")
      cls.constants[interp.symbols.intern("IGNORECASE").value] = Value.int(IGNORECASE)
      cls.constants[interp.symbols.intern("EXTENDED").value] = Value.int(EXTENDED)
      cls.constants[interp.symbols.intern("MULTILINE").value] = Value.int(MULTILINE)

      source_sym = interp.symbols.intern("__source").value
      options_sym = interp.symbols.intern("__options").value

      # `Regexp.new(pattern_or_regexp, options = 0)` — the constructor
      # form, alongside `/pattern/flags` literal syntax (see
      # VM#make_regexp_object, which shares `compile_regex` with this).
      # Mirrors the mruby fixture's "Regexp.new with regexp" case: given
      # an existing Regexp, copies its source/options rather than
      # treating it as a pattern string.
      define_singleton(cls, interp, "new") do |args, _blk, ncc|
        first = args[1]? || Value.nil_value
        pattern, flags =
          if (robj = first.as_robject?) && robj.is_a?(RegexpObject)
            {robj.ivars[source_sym].as_string, robj.ivars[options_sym].as_int.to_i32}
          else
            {first.as_string, (args[2]?.try(&.as_int.to_i32) || 0)}
          end
        regex = compile_regex(pattern, flags, ncc)
        obj = RegexpObject.new(cls, regex)
        obj.ivars[source_sym] = Value.string(pattern)
        obj.ivars[options_sym] = Value.int(flags)
        Value.robject(obj)
      end

      define(cls, interp, "source") do |args|
        args.first.as_robject.ivars[source_sym]
      end

      define(cls, interp, "options") do |args|
        args.first.as_robject.ivars[options_sym]
      end

      define(cls, interp, "casefold?") do |args|
        flags = args.first.as_robject.ivars[options_sym].as_int.to_i32
        Value.bool(flags & IGNORECASE != 0)
      end

      cls
    end
  end
end
