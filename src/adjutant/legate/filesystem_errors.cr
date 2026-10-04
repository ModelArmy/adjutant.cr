require "../ruby_class"
require "../native_call_context"

module Adjutant
  module Legate
    # Raises `Legate::FilesystemError` (LEGATE.md §9.1) for an
    # operating-system failure no verb foresaw: a file where a directory
    # should be, permission denied, a full disk. Foreseen failures, such
    # as a missing source or an occupied destination, are each verb's
    # own `NotFoundError` or `ConflictError`, raised before the call
    # that could fail.
    struct FilesystemErrors
      # `verb` opens every message, as `Legate.cp!` does.
      def initialize(@filesystem : RubyClass, @ncc : NativeCallContext, @verb : String)
      end

      # The block's value. An `IO::Error` it raises becomes
      # `Legate::FilesystemError`; `path` names the file when the error
      # doesn't, as a read's doesn't.
      def guard(path : String? = nil, &)
        yield
      rescue ex : IO::Error
        @ncc.raise_error_class(message(ex, path || ex.as?(File::Error).try(&.file)), @filesystem)
      end

      # The verb, the path, then the system's reason and errno, as
      # Ruby's `Errno` messages give them. A file in the way of a
      # directory is named as such, whichever errno reported it.
      private def message(ex : IO::Error, path : String?) : String
        os_error = ex.os_error
        if path && (blocker = file_in_the_way(path, os_error))
          return "#{@verb} — #{blocker} is a file, not a directory (ENOTDIR)"
        end

        reason = os_error.is_a?(Errno) ? "#{os_error.message} (#{os_error})" : ex.message.to_s
        path ? "#{@verb} — #{path}: #{reason}" : "#{@verb} — #{reason}"
      end

      # `path`, or its nearest existing ancestor, when that is a file
      # and the error says a directory was needed: `ENOTDIR`, or
      # `EEXIST` from creating a directory where the file is, as
      # `FileUtils.mkdir_p` does. Nil otherwise.
      private def file_in_the_way(path : String, os_error) : String?
        return unless os_error == Errno::ENOTDIR || os_error == Errno::EEXIST

        target = ::Path.new(path)
        ([target] + target.parents.reverse).each do |candidate|
          info = File.info?(candidate)
          next unless info
          return info.directory? ? nil : candidate.to_s
        end
        nil
      end
    end
  end
end
