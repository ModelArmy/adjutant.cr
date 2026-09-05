require "../../spec_helper"

module Adjutant
  # `Legate::Chunk` is broker-manufactured only — no script-visible
  # `.new` (by design, same convention as every other Legate value
  # type). This registers a throwaway native trigger, `make_chunk`,
  # that builds one directly from a Crystal String via `Chunk.build`,
  # matching exceptions_spec.cr/value_types_spec.cr's own established
  # pattern for exercising a value type ahead of any real verb that
  # manufactures it. `Legate.bytes` (bytes_spec.cr) is the REAL
  # construction path once it exists as a stream terminal producing
  # actual chunks — this spec is about `Chunk`'s own method surface in
  # isolation, not about streaming.
  private def self.interp_with_chunk_trigger : Interpreter
    interp, _ = make_interp
    chunk_cls = interp.get_global("Legate").as_rclass.constants[interp.symbols.intern("Chunk").value].as_rclass
    interp.modules.register("test/legate_chunk_trigger") do |i|
      i.define_native("make_chunk") do |args, _blk, _ncc|
        str = args[0].as_string
        Legate::Chunk.build(chunk_cls, str.to_slice)
      end
    end
    interp.modules.require("test/legate_chunk_trigger", interp)
    interp
  end

  describe "Legate::Chunk" do
    it "reports the right size" do
      interp = interp_with_chunk_trigger
      interp.eval(%(make_chunk("hello").size)).as_int.should eq 5
    end

    it "indexes a single byte as an Integer 0-255, not a substring" do
      interp = interp_with_chunk_trigger
      interp.eval(%(make_chunk("AB")[0])).as_int.should eq 65 # 'A'
    end

    it "returns nil for an out-of-range index" do
      interp = interp_with_chunk_trigger
      interp.eval(%(make_chunk("A")[99])).raw.nil?.should be_true
    end

    it "returns nil for a negative index" do
      interp = interp_with_chunk_trigger
      interp.eval(%(make_chunk("A")[-1])).raw.nil?.should be_true
    end

    it "#to_a returns a plain Array of Integer bytes" do
      interp = interp_with_chunk_trigger
      interp.eval(%(make_chunk("AB").to_a)).as_array.to_a.map(&.as_int).should eq [65_i64, 66_i64]
    end

    it "#to_s converts back to a real String" do
      interp = interp_with_chunk_trigger
      interp.eval(%(make_chunk("hello").to_s)).as_string.should eq "hello"
    end

    it "#each_byte yields every byte as an Integer and returns self" do
      interp = interp_with_chunk_trigger
      eval = interp.eval(<<-RUBY)
      out = []
      chunk = make_chunk("AB")
      result = chunk.each_byte { |b| out << b }
      [out, result.to_s]
      RUBY
      arr = eval.as_array.to_a
      arr[0].as_array.to_a.map(&.as_int).should eq [65_i64, 66_i64]
      arr[1].as_string.should eq "AB"
    end

    it "#+ concatenates two chunks" do
      interp = interp_with_chunk_trigger
      interp.eval(%((make_chunk("foo") + make_chunk("bar")).to_s)).as_string.should eq "foobar"
    end

    it "#empty? is true for a zero-length chunk" do
      interp = interp_with_chunk_trigger
      interp.eval(%(make_chunk("").empty?)).as_bool.should be_true
    end

    it "#empty? is false for a non-empty chunk" do
      interp = interp_with_chunk_trigger
      interp.eval(%(make_chunk("x").empty?)).as_bool.should be_false
    end
  end
end
