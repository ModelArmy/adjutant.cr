{% if flag?(:windows) %}
  lib LibC
    fun GetFinalPathNameByHandleW(hFile : HANDLE, lpszFilePath : LPWSTR, cchFilePath : DWORD, dwFlags : DWORD) : DWORD
  end
{% end %}

module Adjutant
  # Where a filesystem path leads: what `Grants` checks containment
  # on, and the form in which a risk-flow policy matches a path.
  #
  #   RealPath.of("/work/./repo/../notes.txt") # => "/work/notes.txt", if /work is real
  #   RealPath.of("/work/link")                # => the link's target, resolved
  module RealPath
    # The path a policy matches for `path`: its real path, or for a
    # path that doesn't exist yet the prospective one (`prospective`),
    # normalised and in `/` form, as `Legate::Path` shows paths to
    # scripts. Nil when no ancestor resolves.
    def self.of(path : String) : String?
      prospective(path).try { |full| ::Path.new(full).normalize.to_posix.to_s }
    end

    # The path `path` reaches, every link on the way followed, or nil
    # if it can't be resolved for any reason. `File.realpath`, except
    # on Windows, where Crystal's follows only a final link
    # (`final_path`).
    def self.resolve(path : String) : String?
      {% if flag?(:windows) %}
        final_path(path)
      {% else %}
        File.realpath(path)
      {% end %}
    rescue
      nil
    end

    {% if flag?(:windows) %}
      # The path the kernel reaches opening `path`, as
      # `GetFinalPathNameByHandleW` reports it: every link followed and
      # short names (`RUNNER~1`) expanded. Nil when it can't be opened.
      private def self.final_path(path : String) : String?
        handle = LibC.CreateFileW(path.check_no_null_byte.to_utf16.to_unsafe, 0, LibC::DEFAULT_SHARE_MODE, nil,
          LibC::OPEN_EXISTING, LibC::FILE_FLAG_BACKUP_SEMANTICS, LibC::HANDLE.null)
        return if handle == LibC::INVALID_HANDLE_VALUE
        begin
          size = LibC.GetFinalPathNameByHandleW(handle, Pointer(LibC::WCHAR).null, 0, 0)
          return if size == 0
          buffer = Slice(LibC::WCHAR).new(size)
          length = LibC.GetFinalPathNameByHandleW(handle, buffer, size, 0)
          return if length == 0 || length >= size
          without_verbatim_prefix(String.from_utf16(buffer[0, length]))
        ensure
          LibC.CloseHandle(handle)
        end
      end

      # `path` without the `\\?\` prefix `GetFinalPathNameByHandleW`
      # adds, so it compares with paths as written: `\\?\C:\x` is
      # `C:\x`, and `\\?\UNC\host\share` is `\\host\share`.
      private def self.without_verbatim_prefix(path : String) : String
        if path.starts_with?("\\\\?\\UNC\\")
          "\\\\" + path[8..]
        elsif path.starts_with?("\\\\?\\")
          path[4..]
        else
          path
        end
      end
    {% end %}

    # The real path of `path` if it exists; otherwise the real path of
    # its deepest existing ancestor with the missing components
    # appended as written. Nil when no ancestor resolves.
    def self.prospective(path : String) : String?
      ancestor = deepest_existing_ancestor(path)
      return unless ancestor
      real_ancestor, trailing = ancestor
      trailing.empty? ? real_ancestor : File.join(real_ancestor, File.join(trailing))
    end

    # Dangling links followed while resolving one path before it is
    # denied, as the kernel's own limit denies a loop.
    MAX_LINK_HOPS = 40

    # The realpath of `path`'s deepest existing ancestor, with the
    # missing components below it in order. A dangling symlink on the
    # way up is replaced by its target, resolved the same way, since
    # anything created through the link lands there. Nil if no
    # ancestor resolves, or after `MAX_LINK_HOPS` dangling links.
    private def self.deepest_existing_ancestor(path : String, hops : Int32 = 0) : {String, Array(String)}?
      trailing = [] of String
      current = path
      loop do
        if real = resolve(current)
          return {real, trailing}
        end
        if File.symlink?(current)
          return if hops >= MAX_LINK_HOPS
          # Joined, not normalized: a `..` in the target is left for
          # `resolve` to apply after following links, as the kernel
          # does.
          return unless link = File.readlink?(current)
          target = ::Path.new(link).absolute? ? link : File.join(File.dirname(current), link)
          ancestor = deepest_existing_ancestor(target, hops + 1)
          return unless ancestor
          real_target, target_trailing = ancestor
          return {real_target, target_trailing + trailing}
        end
        parent = File.dirname(current)
        return if parent == current
        trailing.unshift(File.basename(current))
        current = parent
      end
    end
  end
end
