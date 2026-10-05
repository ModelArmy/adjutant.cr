require "./real_path"

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

      real_path = RealPath.resolve(path)
      return Decision.deny("#{path} does not exist or could not be resolved") unless real_path

      under_root = roots.any? { |root| under?(real_path, root) }

      under_root ? Decision.allow : Decision.deny("#{path} (resolved: #{real_path}) is not under any granted root")
    end

    # `check_root` for a path that may not exist yet: a write target,
    # or a verb that returns nil for a missing path. The deepest
    # existing ancestor is resolved and the missing components are
    # appended as written; containment is checked on that prospective
    # path, so a path outside every root is denied whether or not it
    # exists. A dangling symlink counts as its target. A missing
    # component that is later created as a symlink is not caught, the
    # same race §8.1 accepts.
    def check_root_maybe_missing(path : String, roots : Array(String)) : Decision
      return Decision.deny("no roots granted for this operation") if roots.empty?

      prospective = RealPath.prospective(path)
      return Decision.deny("#{path} has no resolvable ancestor directory") unless prospective

      under_root = roots.any? { |root| under_maybe_missing?(prospective, root) }

      under_root ? Decision.allow : Decision.deny("#{path} (prospective: #{prospective}) is not under any granted root")
    end

    # Whether `path` is `root` or inside it, by path algebra, so
    # Windows separators and drives are handled by Crystal. Both should
    # be resolved. A path with a different anchor, such as another
    # drive or a UNC share, is outside.
    def self.contains?(root : ::Path, path : ::Path) : Bool
      rel = path.relative_to?(root)
      return false unless rel
      return true if rel.to_s == "."
      rel.parts.first? != ".."
    end

    # Whether the resolved `real_path` is `root` or inside it.
    private def under?(real_path : String, root : String) : Bool
      real_root = RealPath.resolve(root)
      return false unless real_root

      Grants.contains?(::Path.new(real_root), ::Path.new(real_path))
    end

    # `under?` for a root that may not exist yet either, as when a
    # script creates its granted output directory with `Legate.mkdir`.
    # A missing root is resolved as `check_root_maybe_missing`
    # resolves a path. `check_root` keeps requiring an existing root:
    # a read grant on a missing directory is a misconfiguration.
    private def under_maybe_missing?(prospective_path : String, root : String) : Bool
      effective_root = RealPath.prospective(root)
      return false unless effective_root

      Grants.contains?(::Path.new(effective_root), ::Path.new(prospective_path))
    end
  end
end
