require "../../../spec_helper"
require "file_utils"

private def with_tmpdir(&)
  path = File.join(Dir.tempdir, "adjutant-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir(path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

module Adjutant
  describe "Legate.records" do
    describe "format: :jsonl" do
      it "parses one JSON object per line, with SYMBOL top-level keys" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.jsonl")
          File.write(file, %({"name":"a","n":1}\n{"name":"b","n":2}\n))
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          eval = interp.eval(<<-RUBY)
          Legate.records(#{(file).inspect}, format: :jsonl).to_a.map { |r| [r[:name], r[:n]] }
          RUBY
          arr = eval.as_array.to_a
          arr.map { |pair| pair.as_array.to_a[0].as_string }.should eq ["a", "b"]
          arr.map { |pair| pair.as_array.to_a[1].as_int }.should eq [1_i64, 2_i64]
        end
      end

      it "keeps nested Hash values String-keyed, not symbolized" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.jsonl")
          File.write(file, %({"outer":{"inner":1}}\n))
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          eval = interp.eval(<<-RUBY)
          r = Legate.records(#{(file).inspect}, format: :jsonl).to_a.first
          r[:outer]["inner"]
          RUBY
          eval.as_int.should eq 1_i64
        end
      end

      it "returns an empty Array for an empty file" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.jsonl")
          File.write(file, "")
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          eval = interp.eval(%(Legate.records(#{(file).inspect}, format: :jsonl).to_a))
          eval.as_array.to_a.should be_empty
        end
      end

      it "raises Legate::Malformed on a line that isn't valid JSON" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.jsonl")
          File.write(file, %({"ok":true}\nnot json\n))
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          eval = interp.eval(<<-RUBY)
          begin
            Legate.records(#{(file).inspect}, format: :jsonl).to_a
            "no error"
          rescue Legate::Malformed
            "caught"
          end
          RUBY
          eval.as_string.should eq "caught"
        end
      end
    end

    describe "format: :csv" do
      it "parses rows into a SYMBOL-keyed Hash when headers: true (the default)" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.csv")
          File.write(file, "name,age\na,1\nb,2\n")
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          eval = interp.eval(<<-RUBY)
          Legate.records(#{(file).inspect}, format: :csv).to_a.map { |r| [r[:name], r[:age]] }
          RUBY
          eval.as_array.to_a.map { |pair| pair.as_array.to_a[0].as_string }.should eq ["a", "b"]
          eval.as_array.to_a.map { |pair| pair.as_array.to_a[1].as_string }.should eq ["1", "2"]
        end
      end

      it "returns a plain Array of Strings per row when headers: false" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.csv")
          File.write(file, "a,1\nb,2\n")
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          eval = interp.eval(%(Legate.records(#{(file).inspect}, format: :csv, headers: false).to_a))
          rows = eval.as_array.to_a.map { |r| r.as_array.to_a.map(&.as_string) }
          rows.should eq [["a", "1"], ["b", "2"]]
        end
      end

      it "returns an empty Array for a headerless (empty) file" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.csv")
          File.write(file, "")
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          eval = interp.eval(%(Legate.records(#{(file).inspect}, format: :csv).to_a))
          eval.as_array.to_a.should be_empty
        end
      end

      it "raises Legate::Malformed when a row's column count doesn't match the headers" do
        with_tmpdir do |dir|
          file = File.join(dir, "f.csv")
          File.write(file, "a,b\n1,2,3\n")
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          eval = interp.eval(<<-RUBY)
          begin
            Legate.records(#{(file).inspect}, format: :csv).to_a
            "no error"
          rescue Legate::Malformed
            "caught"
          end
          RUBY
          eval.as_string.should eq "caught"
        end
      end
    end

    it "raises an ArgumentError for an unknown format:" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "x\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.records(#{(file).inspect}, format: :xml)
          "no error"
        rescue ArgumentError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "raises Legate::NotFound eagerly, at construction, for a missing path under a granted root" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.records(#{(File.join(dir, "nope.jsonl")).inspect}, format: :jsonl)
          "no error"
        rescue Legate::NotFound
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "raises FatalSignal (denied) eagerly, at construction, for a path outside every granted root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          File.write(File.join(other, "f.jsonl"), %({"a":1}\n))
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
            interp.eval(%(Legate.records(#{(File.join(other, "f.jsonl")).inspect}, format: :jsonl)))
          end
        end
      end
    end

    it "raises Legate::EOF on a second full iteration (single-pass, §6.1)" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.jsonl")
        File.write(file, %({"a":1}\n))
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        s = Legate.records(#{(file).inspect}, format: :jsonl)
        s.to_a
        begin
          s.to_a
          "no error"
        rescue Legate::EOF
          "eof"
        end
        RUBY
        eval.as_string.should eq "eof"
      end
    end

    it "logs exactly one :allowed audit record per invocation" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.jsonl")
        File.write(file, %({"a":1}\n))
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.records(#{(file).inspect}, format: :jsonl)))
        records = interp.broker.audit_log.records.select { |r| r.verb == "read" }
        records.size.should eq 1
        records.first.decision.should eq :allowed
      end
    end

    it "raises TypeError (R036) for a wrong-typed headers: kwarg, not a raw Crystal crash" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.csv")
        File.write(file, "a,b\n1,2\n")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.records(#{(file).inspect}, format: :csv, headers: "yes")
          "no error"
        rescue TypeError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end
  end
end
