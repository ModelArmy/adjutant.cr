module Adjutant
  # The effect boundary for script execution.
  #
  # All physical external effects a script can produce route through
  # this interface. The harness supplies a concrete implementation;
  # scripts cannot bypass it.
  #
  # Capability exposure (which modules a script can require) is handled
  # separately by ModuleRegistry. EffectHandler is strictly for physical
  # effects: output, filesystem access, etc.
  abstract class EffectHandler
    # Write a string to standard output.
    abstract def write_stdout(s : String) : Nil

    # Read a file from the virtual filesystem. Returns nil if not found.
    abstract def vfs_read(path : String) : String?

    # Check whether a path exists in the virtual filesystem.
    abstract def vfs_exists?(path : String) : Bool
  end

  # A capturing EffectHandler for use in tests.
  #
  # Collects stdout output for assertion and supports an in-memory VFS.
  class TestEffectHandler < EffectHandler
    getter stdout_log : Array(String)

    def initialize
      @stdout_log = [] of String
      @vfs = {} of String => String
    end

    def write_stdout(s : String) : Nil
      @stdout_log << s
    end

    def vfs_read(path : String) : String?
      @vfs[path]?
    end

    def vfs_exists?(path : String) : Bool
      @vfs.has_key?(path)
    end

    # Add a file to the in-memory VFS.
    def add_file(path : String, content : String) : Nil
      @vfs[path] = content
    end

    # Return all stdout output as a single string.
    def stdout : String
      @stdout_log.join
    end
  end
end
