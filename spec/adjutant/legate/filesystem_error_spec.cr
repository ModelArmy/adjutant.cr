require "../../spec_helper"
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
  # Runs `call` with read and write granted under `dir`, and returns the
  # class and message of the `Legate::Error` it raises, joined by `|`,
  # or `"no error"`.
  private def self.legate_error_of(dir : String, call : String) : String
    interp, _ = make_interp(grants: Legate::Grants.new(read_roots: [dir], write_roots: [dir]))
    interp.eval(<<-RUBY).as_string
      begin
        #{call}
        "no error"
      rescue Legate::Error => e
        "\#{e.class}|\#{e.message}"
      end
      RUBY
  end

  describe "Legate::Filesystem" do
    it "is a recoverable Legate::Error" do
      eval("Legate::Filesystem.superclass == Legate::Error").truthy?.should be_true
    end

    describe "raised for an operating-system failure no verb foresees" do
      it "cp! to a path beneath a file" do
        with_tmpdir do |dir|
          from = File.join(dir, "report.txt")
          File.write(from, "hi")
          result = legate_error_of(dir, %(Legate.cp!(#{from.inspect}, #{File.join(from, ".bak").inspect})))
          cls, message = result.split('|', 2)
          cls.should eq "Legate::Filesystem"
          message.should contain "Legate.cp!"
          message.should contain "report.txt"
          {% unless flag?(:win32) %}
            message.should match /\(E[A-Z]+\)/
          {% end %}
        end
      end

      it "write to a path beneath a file" do
        with_tmpdir do |dir|
          file = File.join(dir, "notes.txt")
          File.write(file, "hi")
          result = legate_error_of(dir, %(Legate.write(#{File.join(file, "more.txt").inspect}, "x")))
          result.split('|', 2).first.should eq "Legate::Filesystem"
        end
      end

      it "mkdir of a path beneath a file" do
        with_tmpdir do |dir|
          file = File.join(dir, "notes.txt")
          File.write(file, "hi")
          result = legate_error_of(dir, %(Legate.mkdir(#{File.join(file, "sub").inspect})))
          result.split('|', 2).first.should eq "Legate::Filesystem"
        end
      end

      it "reading a directory as lines" do
        with_tmpdir do |dir|
          sub = File.join(dir, "sub")
          Dir.mkdir(sub)
          result = legate_error_of(dir, %(Legate.lines(#{sub.inspect}).to_a))
          cls, message = result.split('|', 2)
          cls.should eq "Legate::Filesystem"
          message.should contain "sub"
        end
      end
    end
  end
end
