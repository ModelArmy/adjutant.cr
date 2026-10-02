module Adjutant
  class VM
    # `target[idx]`, or `target[idx, length]` with `length`, with Ruby's
    # result for each receiver. `safe` gives nil for a nil target.
    private def exec_get_index(target : Value, idx : Value, length : Value?, safe : Bool,
                               filename : String, line : Int32) : Value
      return Value.nil_value if safe && target.null?
      case
      when target.array?
        array_get_index(target.as_array, idx, length, filename, line)
      when target.string?
        string_get_index(target.as_string, target.label, idx, length, filename, line)
      when target.symbol?
        string_get_index(target.as_sym.name, target.label, idx, length, filename, line)
      when target.hash?
        raise_arity_error(2, "1", "Hash#[]", filename, line) if length
        target.as_hash[idx]? || Value.nil_value
      when target.int?
        integer_get_bit(target, idx, length, filename, line)
      else
        object_get_index(target, idx, length, filename, line)
      end
    end

    # An element, or with a Range or length a new Array of the
    # elements selected; nil where Ruby's selection is nil.
    private def array_get_index(arr : LabeledArray, idx : Value, length : Value?,
                                filename : String, line : Int32) : Value
      if length || range_receiver?(idx)
        span = read_span(idx, length, arr.size, filename, line)
        return Value.nil_value unless span
        start, count = span
        Value.new(LabeledArray.new(arr.to_a[start, count], arr.label), arr.label)
      else
        i = integer_index(idx, filename, line)
        i += arr.size if i < 0
        (i >= 0 && i < arr.size) ? arr[i] : Value.nil_value
      end
    end

    # A character, a substring by Range or length, a String found in
    # it, or a Regexp's match (with `length`, a capture group).
    private def string_get_index(s : String, label : RiskFlowLabel?, idx : Value, length : Value?,
                                 filename : String, line : Int32) : Value
      if regexp = idx.as_robject?.try(&.as?(RegexpObject))
        return regexp_index(s, RiskFlowLabel.join(label, idx.label), regexp, length, filename, line)
      end
      if (sub = idx.as_string?) && length.nil?
        return s.includes?(sub) ? Value.string(sub, label) : Value.nil_value
      end
      if length || range_receiver?(idx)
        span = read_span(idx, length, s.size, filename, line)
        return Value.nil_value unless span
        start, count = span
        Value.string(s[start, count], label)
      else
        i = integer_index(idx, filename, line)
        i += s.size if i < 0
        (i >= 0 && i < s.size) ? Value.string(s[i].to_s, label) : Value.nil_value
      end
    end

    # `s[regexp]`, or `s[regexp, capture]` for a numbered or named
    # group; nil without a match or for a group that didn't take part.
    private def regexp_index(s : String, label : RiskFlowLabel?, regexp : RegexpObject, capture : Value?,
                             filename : String, line : Int32) : Value
      md = regexp.regex.match(s)
      return Value.nil_value unless md
      text = if capture.nil?
               md[0]?
             elsif name = capture.as_string? || capture.as_sym?.try(&.name)
               md[name]?
             else
               md[integer_index(capture, filename, line).to_i32]?
             end
      text ? Value.string(text, label) : Value.nil_value
    end

    # `n[i]`: bit `i` of `n` in two's complement, so 0 below bit 0 and
    # the sign bit above bit 63.
    private def integer_get_bit(target : Value, idx : Value, length : Value?,
                                filename : String, line : Int32) : Value
      raise_arity_error(2, "1", "Integer#[]", filename, line) if length
      raise index_conversion_error(idx, filename, line) if range_receiver?(idx)
      n = target.as_int
      i = integer_index(idx, filename, line)
      bit = if i < 0
              0_i64
            elsif i > 63
              n < 0 ? 1_i64 : 0_i64
            else
              (n >> i) & 1
            end
      Value.int(bit, target.label)
    end

    # A Proc is called with the index arguments, and an object with a
    # native `[]` gets it called; anything else raises R047.
    private def object_get_index(target : Value, idx : Value, length : Value?,
                                 filename : String, line : Int32) : Value
      args = length ? [idx, length] : [idx]
      if obj = target.as_robject?
        return invoke_proc(obj, args) if obj.rclass == builtin_class_by_name("Proc")
        if native = native_index_method(obj, "[]")
          return call_native(native, [target] + args, filename, line, nil, "#{obj.rclass.name}#[]", has_receiver: true)
        end
      end
      raise undefined_method_error("[]", target, filename, line)
    end

    # `target[idx] = val`, or `target[idx, length] = val` with `length`.
    private def exec_set_index(target : Value, idx : Value, length : Value?, val : Value,
                               filename : String, line : Int32) : Nil
      case
      when target.array?
        array_set_index(target.as_array, idx, length, val, filename, line)
      when target.hash?
        raise_arity_error(3, "2", "Hash#[]=", filename, line) if length
        h = target.as_hash
        h[idx] = val
        h.label = RiskFlowLabel.join(h.label, val.label)
      when target.string?
        raise runtime_diagnostic(
          Diagnostic.new(code: "R052", primary: Span.new(line: line, filename: filename),
            data: {"value" => target.as_string.inspect}),
          current_frame, error_class: "FrozenError")
      else
        object_set_index(target, idx, length, val, filename, line)
      end
    end

    # Ruby's `Array#[]=`: an index past the end pads with nil, and a
    # Range or length replaces the elements it covers with `val`'s
    # elements, or with `val` itself if it isn't an Array.
    private def array_set_index(arr : LabeledArray, idx : Value, length : Value?, val : Value,
                                filename : String, line : Int32) : Nil
      if length || range_receiver?(idx)
        start, count = write_span(idx, length, arr.size, filename, line)
        replacement = val.as_array?.try(&.to_a.dup) || [val]
        arr.splice(start, count, replacement)
      else
        i = integer_index(idx, filename, line)
        start = i < 0 ? i + arr.size : i
        raise index_too_small(i, arr.size, filename, line) if start < 0
        arr.splice(start.to_i32, start < arr.size ? 1 : 0, [val])
      end
      arr.label = RiskFlowLabel.join(arr.label, val.label)
    end

    # An object with a native `[]=` gets it called; anything else
    # raises R047.
    private def object_set_index(target : Value, idx : Value, length : Value?, val : Value,
                                 filename : String, line : Int32) : Nil
      if (obj = target.as_robject?) && (native = native_index_method(obj, "[]="))
        args = length ? [target, idx, length, val] : [target, idx, val]
        call_native(native, args, filename, line, nil, "#{obj.rclass.name}#[]=", has_receiver: true)
        return
      end
      raise undefined_method_error("[]=", target, filename, line)
    end

    # The start and count a Range, or an index and `length`, selects
    # in a sequence of `size`, or nil where Ruby's read gives nil: a
    # start before the beginning or past the end, or a negative length.
    # A start at the end selects nothing, and a late end is clamped.
    private def read_span(idx : Value, length : Value?, size : Int32,
                          filename : String, line : Int32) : {Int32, Int32}?
      start, stop = if length
                      first = integer_index(idx, filename, line)
                      count = integer_index(length, filename, line)
                      return if count < 0
                      {first, first < 0 ? first + size + count : first + count}
                    else
                      range_bounds(idx, size, filename, line)
                    end
      start += size if start < 0
      return if start < 0 || start > size
      {start.to_i32, (stop - start).clamp(0_i64, (size - start).to_i64).to_i32}
    end

    # The start and count a Range, or an index and `length`, replaces
    # in an Array of `size`. Unlike a read, a start past the end is
    # allowed (the Array is padded), and a start before the beginning
    # raises: R049 for an index, R051 for a Range. A negative length
    # raises R050.
    private def write_span(idx : Value, length : Value?, size : Int32,
                           filename : String, line : Int32) : {Int32, Int32}
      if length
        first = integer_index(idx, filename, line)
        count = integer_index(length, filename, line)
        raise index_diagnostic("R050", {"length" => count.to_s}, "IndexError", filename, line) if count < 0
        start = first < 0 ? first + size : first
        raise index_too_small(first, size, filename, line) if start < 0
        stop = start + count
      else
        start, stop = range_bounds(idx, size, filename, line)
        start += size if start < 0
        if start < 0
          raise index_diagnostic("R051", {"range" => render_inspect(idx, filename, line), "size" => size.to_s},
            "RangeError", filename, line)
        end
      end
      {start.to_i32, (stop - start).clamp(0_i64, Math.max(size - start, 0_i64)).to_i32}
    end

    # A Range's start, before counting a negative one from the end,
    # and its end as an exclusive position with a negative one counted
    # from the end. An open start is 0 and an open end is `size`.
    private def range_bounds(range : Value, size : Int32, filename : String, line : Int32) : {Int64, Int64}
      obj = range.as_robject
      lo = obj.ivars[@symbols.intern("__min").value]
      hi = obj.ivars[@symbols.intern("__max").value]
      exclusive = obj.ivars[@symbols.intern("__exclusive").value].as_bool
      start = lo.null? ? 0_i64 : integer_index(lo, filename, line)
      return {start, size.to_i64} if hi.null?
      stop = integer_index(hi, filename, line)
      stop += size if stop < 0
      stop += 1 unless exclusive
      {start, stop}
    end

    # An index as an Integer: a Float is truncated; anything else
    # raises R048 (TypeError).
    private def integer_index(v : Value, filename : String, line : Int32) : Int64
      if i = v.as_int?
        i
      elsif (f = v.as_float?) && f.finite?
        f.to_i64
      else
        raise index_conversion_error(v, filename, line)
      end
    end

    private def index_conversion_error(v : Value, filename : String, line : Int32) : RuntimeError
      conversion = v.null? ? "from nil to integer" : "of #{Builtins.builtin_type_name(v)} into Integer"
      index_diagnostic("R048", {"conversion" => conversion}, "TypeError", filename, line)
    end

    private def index_too_small(index : Int64, size : Int32, filename : String, line : Int32) : RuntimeError
      index_diagnostic("R049", {"index" => index.to_s, "minimum" => (-size).to_s}, "IndexError", filename, line)
    end

    # R047 (NoMethodError) for a receiver without `method`, described
    # as Ruby does: `nil`, `true`, `class Foo`, or `an instance of Foo`.
    private def undefined_method_error(method : String, target : Value, filename : String, line : Int32) : RuntimeError
      description = case
                    when target.null?   then "nil"
                    when target.bool?   then target.as_bool.to_s
                    when target.rclass? then "#{target.as_rclass.is_module? ? "module" : "class"} #{target.as_rclass.name}"
                    else                     "an instance of #{Builtins.builtin_type_name(target)}"
                    end
      index_diagnostic("R047", {"method" => method, "target" => description}, "NoMethodError", filename, line)
    end

    private def index_diagnostic(code : String, data : Hash(String, String), error_class : String,
                                 filename : String, line : Int32) : RuntimeError
      runtime_diagnostic(
        Diagnostic.new(code: code, primary: Span.new(line: line, filename: filename), data: data),
        current_frame, error_class: error_class)
    end

    # `obj`'s native `[]` or `[]=`, if its class has one.
    private def native_index_method(obj : RubyObject, name : String) : NativeCallable?
      sym_id = @symbols.lookup(name).try(&.value)
      sym_id ? obj.rclass.find_native_method(sym_id) : nil
    end
  end
end
