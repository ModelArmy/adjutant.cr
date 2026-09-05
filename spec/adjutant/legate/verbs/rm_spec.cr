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
    it "removes a file and returns true" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(%(Legate.rm(#{(file).inspect})))
        eval.as_bool.should be_true
        File.exists?(file).should be_false
      end
    end

    it "returns false for a missing path rather than raising" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(%(Legate.rm(#{(File.join(dir, "gone.txt")).inspect})))
        eval.as_bool.should be_false
      end
    end

    # Authorization runs FIRST and in full: "you may not delete here"
    # is true regardless of whether anything is there.
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

    # The §4.4 reversal, from rm's side. The old verb removed an empty
    # directory itself; it now refuses and names the verb that does.
    it "raises Legate::Conflict on a directory, empty or not, and names rmdir" do
      with_tmpdir do |dir|
        target = File.join(dir, "sub")
        Dir.mkdir(target)
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.rm(#{(target).inspect})
          "no error"
        rescue Legate::Conflict => e
          e.message
        end
        RUBY
        eval.as_string.should contain "Legate.rmdir"
        File.directory?(target).should be_true
      end
    end

    # `recursive:` is gone from this verb entirely — it was never a
    # meaningful thing to ask of a file. The two kwarg-validation
    # tests that used to live here are deleted rather than moved:
    # there is no kwarg on any of the three verbs to validate.
    it "no longer accepts a recursive: kwarg at all (R012)" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        error = expect_raises(RuntimeError) do
          interp.eval(%(Legate.rm(#{(file).inspect}, recursive: true)))
        end
        error.diagnostic.not_nil!.code.should eq("R012")
        File.exists?(file).should be_true
      end
    end

    # In-root link to an in-root file: the perimeter allows it, and
    # `follow_symlinks: false` is what makes `rm` answer about the
    # ENTRY the script named rather than the content behind it.
    it "removes a symlink itself, never the file it points at" do
      with_tmpdir do |dir|
        target = File.join(dir, "secret.txt")
        File.write(target, "secret")
        link = File.join(dir, "link.txt")
        File.symlink(target, link)
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(%(Legate.rm(#{(link).inspect})))
        eval.as_bool.should be_true
        File.symlink?(link).should be_false
        File.read(target).should eq "secret"
      end
    end

    # A link pointing OUT of every granted root never reaches this
    # verb at all: `check_root_maybe_missing` realpaths it and the
    # broker denies. Asserted so the next reader does not re-derive
    # it — and so the day that stops being true, this file says so.
    it "is denied by the perimeter for a link pointing outside every delete root" do
      with_tmpdir do |dir|
        with_tmpdir do |outside|
          target = File.join(outside, "secret.txt")
          File.write(target, "secret")
          link = File.join(dir, "link.txt")
          File.symlink(target, link)
          interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.delete denied/) do
            interp.eval(%(Legate.rm(#{(link).inspect})))
          end
          File.read(target).should eq "secret"
          File.symlink?(link).should be_true
        end
      end
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

    it "denies with only a write grant on the same directory" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(write_roots: [dir]))
        expect_raises(Legate::FatalSignal, /Legate\.delete denied/) do
          interp.eval(%(Legate.rm(#{(file).inspect})))
        end
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
  end

  describe "Legate.rmdir" do
    it "removes an empty directory and returns true" do
      with_tmpdir do |dir|
        target = File.join(dir, "sub")
        Dir.mkdir(target)
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(%(Legate.rmdir(#{(target).inspect})))
        eval.as_bool.should be_true
        File.exists?(target).should be_false
      end
    end

    it "returns false for a missing path rather than raising" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(%(Legate.rmdir(#{(File.join(dir, "gone")).inspect})))
        eval.as_bool.should be_false
      end
    end

    it "raises Legate::Conflict on a non-empty directory and names rmdir!" do
      with_tmpdir do |dir|
        target = File.join(dir, "sub")
        Dir.mkdir(target)
        File.write(File.join(target, "keep.txt"), "keep")
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.rmdir(#{(target).inspect})
          "no error"
        rescue Legate::Conflict => e
          e.message
        end
        RUBY
        eval.as_string.should contain "Legate.rmdir!"
        File.read(File.join(target, "keep.txt")).should eq "keep"
      end
    end

    it "raises Legate::Conflict on a file and names rm" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.rmdir(#{(file).inspect})
          "no error"
        rescue Legate::Conflict => e
          e.message
        end
        RUBY
        eval.as_string.should contain "Legate.rm"
        File.exists?(file).should be_true
      end
    end

    it "denies with a FatalSignal for a path outside every granted delete root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          target = File.join(other, "sub")
          Dir.mkdir(target)
          interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.delete denied/) do
            interp.eval(%(Legate.rmdir(#{(target).inspect})))
          end
          File.directory?(target).should be_true
        end
      end
    end
  end

  describe "Legate.rmdir!" do
    it "removes a tree and counts every entry, the directory itself included" do
      with_tmpdir do |dir|
        root = File.join(dir, "tree")
        Dir.mkdir(root)
        Dir.mkdir(File.join(root, "sub"))
        File.write(File.join(root, "top.txt"), "top")
        File.write(File.join(root, "sub", "deep.txt"), "deep")
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(%(Legate.rmdir!(#{(root).inspect})))
        eval.as_int.should eq 4
        File.exists?(root).should be_false
      end
    end

    it "counts dotfiles, which a Dir.glob-based walk would silently miss" do
      with_tmpdir do |dir|
        root = File.join(dir, "tree")
        Dir.mkdir(root)
        File.write(File.join(root, ".hidden"), "x")
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(%(Legate.rmdir!(#{(root).inspect})))
        eval.as_int.should eq 2
      end
    end

    it "returns 0 for a missing path rather than raising" do
      with_tmpdir do |dir|
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(%(Legate.rmdir!(#{(File.join(dir, "gone")).inspect})))
        eval.as_int.should eq 0
      end
    end

    it "removes an empty directory too — the bang is a superset of rmdir" do
      with_tmpdir do |dir|
        target = File.join(dir, "sub")
        Dir.mkdir(target)
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(%(Legate.rmdir!(#{(target).inspect})))
        eval.as_int.should eq 1
        File.exists?(target).should be_false
      end
    end

    it "raises Legate::Conflict on a file and names rm" do
      with_tmpdir do |dir|
        file = File.join(dir, "f.txt")
        File.write(file, "hi")
        interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
        eval = interp.eval(<<-RUBY)
        begin
          Legate.rmdir!(#{(file).inspect})
          "no error"
        rescue Legate::Conflict => e
          e.message
        end
        RUBY
        eval.as_string.should contain "Legate.rm"
        File.exists?(file).should be_true
      end
    end

    # Non-following applies to the ENTRIES INSIDE the tree as well as
    # to the target: a link within a granted delete root must not
    # become a lever for removing something outside every root.
    it "does not descend into a symlinked directory inside the tree" do
      with_tmpdir do |dir|
        with_tmpdir do |outside|
          File.write(File.join(outside, "secret.txt"), "secret")
          root = File.join(dir, "tree")
          Dir.mkdir(root)
          File.symlink(outside, File.join(root, "link"))
          interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
          eval = interp.eval(%(Legate.rmdir!(#{(root).inspect})))
          eval.as_int.should eq 2 # the tree and the link, not what it points at
          File.read(File.join(outside, "secret.txt")).should eq "secret"
        end
      end
    end

    it "denies with a FatalSignal for a path outside every granted delete root" do
      with_tmpdir do |dir|
        with_tmpdir do |other|
          root = File.join(other, "tree")
          Dir.mkdir(root)
          interp, _ = make_interp(grants: Legate::Grants.new(delete_roots: [dir]))
          expect_raises(Legate::FatalSignal, /Legate\.delete denied/) do
            interp.eval(%(Legate.rmdir!(#{(root).inspect})))
          end
          File.directory?(root).should be_true
        end
      end
    end
  end
end
