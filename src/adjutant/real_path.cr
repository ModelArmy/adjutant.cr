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

    # `File.realpath`, or nil if the path can't be resolved for any
    # reason.
    def self.resolve(path : String) : String?
      File.realpath(path)
    rescue
      nil
    end

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
          # `File.realpath` to apply after following links, as the
          # kernel does.
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
