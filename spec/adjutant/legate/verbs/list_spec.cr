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
  describe "Legate.list" do
    it "matches files with a simple glob, sorted lexically" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "b.txt"), "")
        File.write(File.join(dir, "a.txt"), "")
        File.write(File.join(dir, "c.log"), "")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        Legate.list(#{(File.join(dir, "*.txt")).inspect}).map { |e| e.path.to_s }
        RUBY
        arr = eval.as_array.to_a.map(&.as_string)
        arr.should eq [File.join(dir, "a.txt"), File.join(dir, "b.txt")]
      end
    end

    it "matches recursively with **" do
      with_tmpdir do |dir|
        Dir.mkdir(File.join(dir, "sub"))
        File.write(File.join(dir, "top.rb"), "")
        File.write(File.join(dir, "sub", "nested.rb"), "")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        Legate.list(#{(File.join(dir, "**", "*.rb")).inspect}).map { |e| e.path.to_s }
        RUBY
        arr = eval.as_array.to_a.map(&.as_string)
        arr.should contain(File.join(dir, "top.rb"))
        arr.should contain(File.join(dir, "sub", "nested.rb"))
      end
    end

    it "returns an empty Array, not an error, for a pattern that matches nothing" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(%(Legate.list(#{(File.join(dir, "*.nope")).inspect})))
        eval.as_array.to_a.should be_empty
      end
    end

    it "returns an empty Array when the fixed prefix directory doesn't exist at all" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(%(Legate.list(#{(File.join(dir, "nosuchdir", "*.txt")).inspect})))
        eval.as_array.to_a.should be_empty
      end
    end

    it "reports the right type on each Entry" do
      with_tmpdir do |dir|
        Dir.mkdir(File.join(dir, "subdir"))
        File.write(File.join(dir, "f.txt"), "hello")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        Legate.list(#{(File.join(dir, "*")).inspect}).map { |e| e.type }
        RUBY
        pairs = eval.as_array.to_a.map(&.as_sym.name)
        pairs.should contain("file")
        pairs.should contain("dir")
      end
    end

    it "reports the correct file size" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "f.txt"), "hello")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        Legate.list(#{(File.join(dir, "f.txt")).inspect}).first.size
        RUBY
        eval.as_int.should eq 5_i64
      end
    end

    it "reports :symlink for a matched symlink, without following it" do
      with_tmpdir do |dir|
        target = File.join(dir, "target.txt")
        File.write(target, "hello")
        link = File.join(dir, "link.txt")
        File.symlink(target, link)
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        Legate.list(#{(File.join(dir, "link.txt")).inspect}).map { |e| e.type }
        RUBY
        eval.as_array.to_a.first.as_sym.name.should eq "symlink"
      end
    end

    it "raises Legate::TooMany when matches exceed limit:" do
      with_tmpdir do |dir|
        3.times { |i| File.write(File.join(dir, "f#{i}.txt"), "") }
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.list(#{(File.join(dir, "*.txt")).inspect}, limit: 2)
        rescue Legate::TooMany => e
          "caught: \#{e.message}"
        end
        RUBY
        eval.as_string.should match(/caught: .*matched 3 entries, over the 2 limit/)
      end
    end

    it "denies with a FatalSignal when the fixed prefix is outside every granted root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          File.write(File.join(other, "f.txt"), "")
          interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
            interp.eval(%(Legate.list(#{(File.join(other, "*.txt")).inspect})))
          end
        end
      end
    end

    it "denies with no read grant at all" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "f.txt"), "")
        interp, _ = make_interp(grants: Legate::Grants.deny_all)
        expect_raises(Legate::FatalSignal, /Legate\.read denied/) do
          interp.eval(%(Legate.list(#{(File.join(dir, "*.txt")).inspect})))
        end
      end
    end

    it "logs exactly one :allowed audit record per call, regardless of match count" do
      with_tmpdir do |dir|
        5.times { |i| File.write(File.join(dir, "f#{i}.txt"), "") }
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        interp.eval(%(Legate.list(#{(File.join(dir, "*.txt")).inspect})))
        records = interp.broker.audit_log.records.select { |r| r.verb == "read" }
        records.size.should eq 1
        records.first.decision.should eq :allowed
      end
    end

    it "raises TypeError (R036) for a wrong-typed limit: kwarg, not a raw Crystal crash" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.list(#{(File.join(dir, "*.txt")).inspect}, limit: "lots")
          "no error"
        rescue TypeError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    it "each Entry's path.basename returns just the filename, not the whole path" do
      with_tmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir]))
        eval = interp.eval(%(Legate.list(#{(File.join(dir, "*.txt")).inspect}).map { |e| e.path.basename }))
        eval.as_array.to_a.map(&.as_string).should eq ["a.txt"]
      end
    end
  end
end
