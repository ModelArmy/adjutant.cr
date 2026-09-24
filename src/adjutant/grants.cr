module Adjutant
  # The static perimeter: which filesystem roots a run may touch, and
  # the checks that a subject lies inside them. Core rather than
  # Legate, since containment under a root mentions no verb.
  #
  # Network rules stay in `Legate::Grants`, which subclasses this, so
  # a broker holds one grants object. These checks are static: the
  # risk-flow check runs after they pass, never instead, and
  # resolved-address checks (LEGATE.md §8.2) belong to whatever opens
  # the connection.
  class Grants
    # A check's outcome. `reason` explains a denial and is written to
    # be shown as-is, not parsed.
    struct Decision
      getter? allowed : Bool
      getter reason : String?

      def initialize(@allowed : Bool, @reason : String? = nil)
      end

      def self.allow : Decision
        new(true)
      end

      def self.deny(reason : String) : Decision
        new(false, reason)
      end
    end

    getter read_roots : Array(String)
    getter write_roots : Array(String)
    getter delete_roots : Array(String)

    def initialize(@read_roots = [] of String, @write_roots = [] of String,
                   @delete_roots = [] of String)
    end

    # Whether `path`, which must exist, resolves (with symlinks, via
    # `File.realpath`) under one of `roots`, also resolved. The caller
    # picks which roots list applies. LEGATE.md §8.1 accepts the race
    # between this check and the open. For a path that may not exist
    # yet, use `check_root_maybe_missing`.
    def check_root(path : String, roots : Array(String)) : Decision
      return Decision.deny("no roots granted for this operation") if roots.empty?

      real_path = resolve(path)
      return Decision.deny("#{path} does not exist or could not be resolved") unless real_path

      under_root = roots.any? { |root| under?(real_path, root) }

      under_root ? Decision.allow : Decision.deny("#{path} (resolved: #{real_path}) is not under any granted root")
    end

    # `check_root` for a path that may not exist yet: a write target,
    # or a verb that returns nil for a missing path. The deepest
    # existing ancestor is resolved and the missing components are
    # appended as written; containment is checked on that prospective
    # path, so a path outside every root is denied whether or not it
    # exists. A missing component that is later created as a symlink
    # is not caught, the same race §8.1 accepts.
    def check_root_maybe_missing(path : String, roots : Array(String)) : Decision
      return Decision.deny("no roots granted for this operation") if roots.empty?

      ancestor = deepest_existing_ancestor(path)
      return Decision.deny("#{path} has no resolvable ancestor directory") unless ancestor
      real_ancestor, trailing = ancestor
      prospective = trailing.empty? ? real_ancestor : File.join(real_ancestor, File.join(trailing))

      under_root = roots.any? { |root| under_maybe_missing?(prospective, root) }

      under_root ? Decision.allow : Decision.deny("#{path} (prospective: #{prospective}) is not under any granted root")
    end

    # `File.realpath`, or nil if the path can't be resolved for any
    # reason.
    private def resolve(path : String) : String?
      File.realpath(path)
    rescue
      nil
    end

    # Whether the resolved `real_path` is `root` or inside it, by
    # path algebra (`Path#relative_to`), so Windows separators and
    # drives are handled by Crystal.
    private def under?(real_path : String, root : String) : Bool
      real_root = resolve(root)
      return false unless real_root

      rel = ::Path.new(real_path).relative_to(::Path.new(real_root))
      return true if rel.to_s == "."
      rel.parts.first? != ".."
    end

    # `under?` for a root that may not exist yet either, as when a
    # script creates its granted output directory with `Legate.mkdir`.
    # A missing root is resolved as `check_root_maybe_missing`
    # resolves a path. `check_root` keeps requiring an existing root:
    # a read grant on a missing directory is a misconfiguration.
    private def under_maybe_missing?(prospective_path : String, root : String) : Bool
      effective_root = resolve(root)
      unless effective_root
        root_ancestor = deepest_existing_ancestor(root)
        return false unless root_ancestor
        real_root_ancestor, root_trailing = root_ancestor
        effective_root = root_trailing.empty? ? real_root_ancestor : File.join(real_root_ancestor, File.join(root_trailing))
      end

      rel = ::Path.new(prospective_path).relative_to(::Path.new(effective_root))
      return true if rel.to_s == "."
      rel.parts.first? != ".."
    end

    # The realpath of `path`'s deepest existing ancestor, with the
    # missing components below it in order. Nil if no ancestor
    # resolves.
    private def deepest_existing_ancestor(path : String) : {String, Array(String)}?
      trailing = [] of String
      current = path
      loop do
        if real = resolve(current)
          return {real, trailing}
        end
        parent = File.dirname(current)
        return if parent == current
        trailing.unshift(File.basename(current))
        current = parent
      end
    end
  end
end
