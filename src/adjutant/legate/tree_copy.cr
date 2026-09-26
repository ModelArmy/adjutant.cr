require "../budget"

module Adjutant
  module Legate
    # Copies a directory tree without following symlinks, for
    # `Legate.cp`'s recursive copy and `Legate.mv`'s cross-device
    # fallback. A symlink is recreated with the same target, so nothing
    # outside the tree is read and a link to an ancestor can't loop.
    # Every entry is reached by name from the tree's root, so each lies
    # inside whatever the caller authorized for the root. Both budgets
    # are recorded per chunk, so a copy stops as soon as either is
    # exhausted.
    #
    #   copier = TreeCopy.new(broker.budget) { |file| check(file) }
    #   copier.copy_children("src", "dest") # dest already exists
    class TreeCopy
      CHUNK_SIZE = 65_536

      # Raised for an entry that is not a directory, regular file or
      # symlink (a FIFO, socket or device), which has no content that
      # can be copied safely: a FIFO blocks and a device may not end.
      # The verb reports it as `Legate::Conflict`.
      class SpecialFile < Exception
        getter path : String

        def initialize(@path : String)
          super("#{path} is not a regular file, directory or symlink")
        end
      end

      # `on_file` is called with each regular file's path before it is
      # opened, so the caller can authorize and label it; raising
      # stops the copy.
      def initialize(@budget : ::Adjutant::Budget, &@on_file : String -> Nil)
      end

      # Copies `from`, which isn't followed if it is a symlink, to `to`,
      # which must not exist.
      def copy_entry(from : String, to : String) : Nil
        info = File.info(from, follow_symlinks: false)
        if info.symlink?
          File.symlink(File.readlink(from), to)
        elsif info.directory?
          Dir.mkdir(to)
          copy_children(from, to)
        elsif info.file?
          @on_file.call(from)
          copy_file(from, to)
        else
          raise SpecialFile.new(from)
        end
      end

      # Copies each entry of the directory `from` into the existing
      # directory `to`. `from` itself is followed if it is a symlink.
      def copy_children(from : String, to : String) : Nil
        Dir.children(from).each do |child|
          copy_entry(File.join(from, child), File.join(to, child))
        end
      end

      # Copies content in chunks, then the permissions, as
      # `File.copy` does, and syncs before returning.
      private def copy_file(from : String, to : String) : Nil
        File.open(from, "rb") do |src|
          File.open(to, "wb") do |dst|
            buf = ::Bytes.new(CHUNK_SIZE)
            loop do
              n = src.read(buf)
              break if n == 0
              @budget.record_read(n.to_i64)
              dst.write(buf[0, n])
              @budget.record_write(n.to_i64)
            end
            dst.flush
            dst.chmod(src.info.permissions)
            dst.fsync
          end
        end
      end
    end
  end
end
