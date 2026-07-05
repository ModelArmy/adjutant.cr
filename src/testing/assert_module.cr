module Testing
  # Assert module for script-level specs.
  #
  # Matches the mruby test assert API so mruby test scripts can be
  # borrowed and pruned to what Adjutant supports.
  #
  # Each assertion records its own pass/fail in the module instance rather
  # than raising and aborting the script — this lets a single script file
  # report multiple failing assertions instead of stopping at the first one.
  #
  # Supported:
  #   assert("description") { expr }
  #   assert_equal(expected, actual)
  #   assert_not_equal(expected, actual)
  #   assert_nil(val)
  #   assert_not_nil(val)
  #   assert_true(val)
  #   assert_false(val)
  #   assert_raise { block }
  #   assert_raise(TypeError) { block }         — filters by class (or subclass)
  #   assert_raise(A, B) { block }               — filters by any of A, B
  #   assert_nothing_raised { block }
  class AssertModule < Adjutant::ScriptModule
    record AssertResult, description : String, passed : Bool, message : String?, filename : String, line : Int32, cause : Adjutant::RuntimeError?

    getter results : Array(AssertResult)

    def initialize
      @results = [] of AssertResult
    end

    def name : String
      "assert"
    end

    def passed_count : Int32
      @results.count(&.passed)
    end

    def failed_count : Int32
      @results.count { |result| !result.passed }
    end

    def load(interp : Adjutant::Interpreter) : Nil
      define_assert(interp)
      define_assert_equal(interp)
      define_assert_not_equal(interp)
      define_assert_false(interp)
      define_assert_true(interp)
      define_assert_nil(interp)
      define_assert_not_nil(interp)
      define_assert_raise(interp)
      define_assert_nothing_raised(interp)
    end

    private def define_assert(interp)
      interp.define_native("assert") do |args, blk, ncc|
        desc = args.first?.try { |v| v.string? ? v.as_string : v.to_s } || "assertion"
        if blk
          begin
            result = ncc.invoke(blk, [] of Adjutant::Value)
            record(desc, result.truthy?, result.truthy? ? nil : "block returned falsy", ncc)
          rescue e : Adjutant::RuntimeError
            record(desc, false, "raised: #{e.message}", ncc, cause: e)
          end
        else
          record(desc, false, "no block given", ncc)
        end
        Adjutant::Value.bool(true)
      end
    end

    private def define_assert_equal(interp)
      interp.define_native("assert_equal") do |args, _blk, ncc|
        expected = args[0]? || Adjutant::Value.nil_value
        actual = args[1]? || Adjutant::Value.nil_value
        ok = values_equal?(expected, actual)
        msg = ok ? nil : "expected #{expected.inspect}, got #{actual.inspect}"
        record("assert_equal", ok, msg, ncc)
        Adjutant::Value.bool(true)
      end
    end

    private def define_assert_not_equal(interp)
      interp.define_native("assert_not_equal") do |args, _blk, ncc|
        expected = args[0]? || Adjutant::Value.nil_value
        actual = args[1]? || Adjutant::Value.nil_value
        ok = !values_equal?(expected, actual)
        record("assert_not_equal", ok, ok ? nil : "both are #{actual.inspect}", ncc)
        Adjutant::Value.bool(true)
      end
    end

    private def define_assert_nil(interp)
      interp.define_native("assert_nil") do |args, _blk, ncc|
        val = args.first? || Adjutant::Value.nil_value
        record("assert_nil", val.null?, val.null? ? nil : "got #{val.inspect}", ncc)
        Adjutant::Value.bool(true)
      end
    end

    private def define_assert_not_nil(interp)
      interp.define_native("assert_not_nil") do |args, _blk, ncc|
        val = args.first? || Adjutant::Value.nil_value
        record("assert_not_nil", !val.null?, val.null? ? "got nil" : nil, ncc)
        Adjutant::Value.bool(true)
      end
    end

    private def define_assert_true(interp)
      interp.define_native("assert_true") do |args, _blk, ncc|
        val = args.first? || Adjutant::Value.nil_value
        record("assert_true", val.truthy?, val.truthy? ? nil : "got #{val.inspect}", ncc)
        Adjutant::Value.bool(true)
      end
    end

    private def define_assert_false(interp)
      interp.define_native("assert_false") do |args, _blk, ncc|
        val = args.first? || Adjutant::Value.nil_value
        record("assert_false", val.falsy?, val.falsy? ? nil : "got #{val.inspect}", ncc)
        Adjutant::Value.bool(true)
      end
    end

    private def define_assert_raise(interp)
      # assert_raise { block }               — any error passes
      # assert_raise(TypeError) { block }     — must match TypeError or a subclass
      # assert_raise(A, B) { block }          — must match one of A, B (or a subclass)
      interp.define_native("assert_raise") do |args, blk, ncc|
        expected = args.compact_map(&.as_rclass?)
        if blk
          begin
            ncc.invoke(blk, [] of Adjutant::Value)
            record("assert_raise", false, "no exception was raised", ncc)
          rescue e : Adjutant::RuntimeError
            if expected.empty?
              record("assert_raise", true, nil, ncc, cause: e)
            else
              matched = expected.any? { |cls| error_is_a?(e, cls) }
              msg = matched ? nil : "expected #{expected.map(&.name).join(" or ")}, got #{error_class_name(e)}"
              record("assert_raise", matched, msg, ncc, cause: e)
            end
          end
        else
          record("assert_raise", false, "no block given", ncc)
        end
        Adjutant::Value.bool(true)
      end
    end

    private def define_assert_nothing_raised(interp)
      interp.define_native("assert_nothing_raised") do |_, blk, ncc|
        if blk
          begin
            ncc.invoke(blk, [] of Adjutant::Value)
            record("assert_nothing_raised", true, nil, ncc)
          rescue e : Adjutant::RuntimeError
            record("assert_nothing_raised", false, "raised: #{e.message}", ncc, cause: e)
          end
        else
          record("assert_nothing_raised", false, "no block given", ncc)
        end
        Adjutant::Value.bool(true)
      end
    end

    private def error_is_a?(e : Adjutant::RuntimeError, cls : Adjutant::RubyClass) : Bool
      val = e.error_value
      return false unless val && (obj = val.as_robject?)
      c = obj.rclass.as(Adjutant::RubyClass?)
      while c
        return true if c == cls
        c = c.superclass
      end
      false
    end

    private def error_class_name(e : Adjutant::RuntimeError) : String
      if (val = e.error_value) && (obj = val.as_robject?)
        obj.rclass.name
      else
        "RuntimeError"
      end
    end

    private def record(description : String, passed : Bool, message : String?, ncc : Adjutant::NativeCallContext, cause = nil) : Nil
      @results << AssertResult.new(description, passed, message, ncc.filename, ncc.line, cause)
    end

    # ameba:disable Metrics/CyclomaticComplexity - It is what it is
    private def values_equal?(a : Adjutant::Value, b : Adjutant::Value) : Bool
      case
      when a.null? && b.null?     then true
      when a.bool? && b.bool?     then a.as_bool == b.as_bool
      when a.int? && b.int?       then a.as_int == b.as_int
      when a.float? && b.float?   then a.as_float == b.as_float
      when a.int? && b.float?     then a.as_int.to_f64 == b.as_float
      when a.float? && b.int?     then a.as_float == b.as_int.to_f64
      when a.string? && b.string? then a.as_string == b.as_string
      when a.symbol? && b.symbol? then a.as_sym == b.as_sym
      else                             false
      end
    end
  end
end
