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
      @results.count { |r| !r.passed }
    end

    def load(interp : Adjutant::Interpreter) : Nil
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

      interp.define_native("assert_equal") do |args, _blk, ncc|
        expected = args[0]? || Adjutant::Value.nil_value
        actual = args[1]? || Adjutant::Value.nil_value
        ok = values_equal?(expected, actual)
        msg = ok ? nil : "expected #{expected.inspect}, got #{actual.inspect}"
        record("assert_equal", ok, msg, ncc)
        Adjutant::Value.bool(true)
      end

      interp.define_native("assert_not_equal") do |args, _blk, ncc|
        expected = args[0]? || Adjutant::Value.nil_value
        actual = args[1]? || Adjutant::Value.nil_value
        ok = !values_equal?(expected, actual)
        record("assert_not_equal", ok, ok ? nil : "both are #{actual.inspect}", ncc)
        Adjutant::Value.bool(true)
      end

      interp.define_native("assert_nil") do |args, _blk, ncc|
        val = args.first? || Adjutant::Value.nil_value
        record("assert_nil", val.null?, val.null? ? nil : "got #{val.inspect}", ncc)
        Adjutant::Value.bool(true)
      end

      interp.define_native("assert_not_nil") do |args, _blk, ncc|
        val = args.first? || Adjutant::Value.nil_value
        record("assert_not_nil", !val.null?, val.null? ? "got nil" : nil, ncc)
        Adjutant::Value.bool(true)
      end

      interp.define_native("assert_true") do |args, _blk, ncc|
        val = args.first? || Adjutant::Value.nil_value
        record("assert_true", val.truthy?, val.truthy? ? nil : "got #{val.inspect}", ncc)
        Adjutant::Value.bool(true)
      end

      interp.define_native("assert_false") do |args, _blk, ncc|
        val = args.first? || Adjutant::Value.nil_value
        record("assert_false", val.falsy?, val.falsy? ? nil : "got #{val.inspect}", ncc)
        Adjutant::Value.bool(true)
      end

      # assert_raise { block } — type matching not yet supported.
      interp.define_native("assert_raise") do |args, blk, ncc|
        if blk
          raised = false
          begin
            ncc.invoke(blk, [] of Adjutant::Value)
          rescue Adjutant::RuntimeError
            raised = true
          end
          record("assert_raise", raised, raised ? nil : "no exception was raised", ncc)
        else
          record("assert_raise", false, "no block given", ncc)
        end
        Adjutant::Value.bool(true)
      end
    end

    private def record(description : String, passed : Bool, message : String?, ncc : Adjutant::NativeCallContext, cause = nil) : Nil
      @results << AssertResult.new(description, passed, message, ncc.filename, ncc.line, cause)
    end

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
