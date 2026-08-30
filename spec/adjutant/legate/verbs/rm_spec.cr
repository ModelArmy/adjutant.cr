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
  describe "Legate.rm" do
    it "removes a file and returns 1" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(%(Legate.rm(#{(file).inspect})))
        eval.as_int.should eq 1
        File.exists?(file).should be_false
      end
    end

    # §4.4/§2.3's documented missing-path result — and the reason
    # `Broker#authorize_delete` needed an `allow_missing` parameter at
    # all. Before that change this exact call raised a FATAL,
    # unrescuable denial (the strict `check_root` denies anything it
    # can't resolve) despite the path being squarely inside a granted
    # delete root.
    it "returns 0 for a missing path rather than raising" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(%(Legate.rm(#{(File.join(dir, "gone.txt")).inspect})))
        eval.as_int.should eq 0
      end
    end

    # The other half of the pair above: absence is only forgiving
    # INSIDE a granted root. A missing path outside every delete root
    # is still a denial, because "you may not delete here" holds
    # regardless of whether anything happens to be there.
    it "still denies a missing path that is outside every granted delete root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.delete denied/) do
            interp.eval(%(Legate.rm(#{(File.join(other, "gone.txt")).inspect})))
          end
        end
      end
    end

    it "removes an empty directory without recursive: — rm subsumes rmdir" do
      with_tmpdir do |dir|
        target = File.join(dir, "empty")
        Dir.mkdir(target)
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(%(Legate.rm(#{(target).inspect})))
        eval.as_int.should eq 1
        Dir.exists?(target).should be_false
      end
    end

    it "raises Legate::Conflict on a non-empty directory without recursive:" do
      with_tmpdir do |dir|
        target = File.join(dir, "full")
        Dir.mkdir(target)
        File.write(File.join(target, "a.txt"), "a")
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.rm(#{(target).inspect})
          "no error"
        rescue Legate::Conflict
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
        Dir.exists?(target).should be_true
      end
    end

    it "removes a tree with recursive: true and counts every entry, the directory itself included" do
      with_tmpdir do |dir|
        target = File.join(dir, "tree")
        Dir.mkdir(target)
        Dir.mkdir(File.join(target, "sub"))
        File.write(File.join(target, "a.txt"), "a")
        File.write(File.join(target, "sub", "b.txt"), "b")
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(%(Legate.rm(#{(target).inspect}, recursive: true)))
        # tree + a.txt + sub + sub/b.txt
        eval.as_int.should eq 4
        Dir.exists?(target).should be_false
      end
    end

    # The specific reason `count_entries` is a hand-written
    # `Dir.children` walk rather than a `Dir.glob("**/*")` — glob does
    # not match dotfiles, so this count would silently come back 2
    # instead of 3 under the obvious implementation.
    it "counts dotfiles, which a Dir.glob-based walk would silently miss" do
      with_tmpdir do |dir|
        target = File.join(dir, "tree")
        Dir.mkdir(target)
        File.write(File.join(target, ".hidden"), "h")
        File.write(File.join(target, "visible.txt"), "v")
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(%(Legate.rm(#{(target).inspect}, recursive: true)))
        eval.as_int.should eq 3
      end
    end

    it "removes a symlink itself, never the file it points at" do
      {% if flag?(:unix) %}
        with_tmpdir do |dir|
          real = File.join(dir, "real.txt")
          link = File.join(dir, "link.txt")
          File.write(real, "content")
          File.symlink(real, link)
          interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
          eval = interp.eval(%(Legate.rm(#{(link).inspect})))
          eval.as_int.should eq 1
          File.exists?(link).should be_false
          File.read(real).should eq "content"
        end
      {% end %}
    end

    it "denies with a FatalSignal for a path outside every granted delete root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          file = File.join(other, "f.txt")
          File.write(file, "hi")
          interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.delete denied/) do
            interp.eval(%(Legate.rm(#{(file).inspect})))
          end
          File.exists?(file).should be_true
        end
      end
    end

    # A `write` grant is emphatically NOT a `delete` grant — §4.4's
    # whole separability argument in one assertion.
    it "denies with only a write grant on the same directory" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        expect_raises(Legate::FatalSignal, /Legate\.delete denied/) do
          interp.eval(%(Legate.rm(#{(file).inspect})))
        end
        File.exists?(file).should be_true
      end
    end

    it "logs exactly one :allowed audit record per invocation" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        interp.eval(%(Legate.rm(#{(file).inspect})))
        records = interp.broker.audit_log.records.select { |r| r.verb == "delete" }
        records.size.should eq 1
        records.first.decision.should eq :allowed
      end
    end

    it "raises TypeError (R036) for a wrong-typed recursive: kwarg, not a raw Crystal crash" do
      with_tmpdir do |dir|
        target = File.join(dir, "tree")
        Dir.mkdir(target)
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.rm(#{(target).inspect}, recursive: "yes")
          "no error"
        rescue TypeError
          "caught"
        end
        RUBY
        eval.as_string.should eq "caught"
      end
    end

    # Convention 1: kwarg validation happens BEFORE authorize_*, so a
    # call that fails on a bad kwarg burns no audit-log entry.
    it "validates the recursive: kwarg before authorizing, consuming no audit record" do
      with_tmpdir do |dir|
        target = File.join(dir, "tree")
        Dir.mkdir(target)
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        interp.eval(<<-RUBY)
        begin
          Legate.rm(#{(target).inspect}, recursive: 1)
        rescue TypeError
        end
        RUBY
        interp.broker.audit_log.records.select { |r| r.verb == "delete" }.size.should eq 0
      end
    end
  end
end
