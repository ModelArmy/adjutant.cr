module Adjutant
  # The static perimeter: which filesystem roots and which executables
  # a run is permitted to touch, and the checks that answer "is this
  # subject inside it".
  #
  # Core rather than Legate (moved 2026-09-01 — see SCOPE.md's
  # "Authorization is a Legate-private mechanism, but it is not a
  # Legate-shaped problem"): containment under a root and membership in
  # an allowlist are predicates over paths and binaries. Neither
  # mentions a verb, and anything that ever reaches outside the VM
  # should inherit them rather than reimplement them.
  #
  # Deliberately THIN. Network rule matching is NOT here: a rule that
  # authorizes a connection has to know something about the protocol
  # (HTTP methods today, recipients or sender domains if SMTP ever
  # arrives), and those are different questions wearing the same shape.
  # Until a second protocol actually exists, all of it stays with
  # Legate — see `Legate::Grants` — rather than being generalised on
  # the strength of an argument. Same for the ambient-env allowlist:
  # there is no `check_env` predicate for core to own.
  #
  # Subclassed, not composed: `Legate::Grants` extends this with its
  # own net rules and limits, so a broker still holds ONE grants
  # object rather than two halves it has to keep in step.
  #
  # STATIC only. This decides what a config permits structurally,
  # without looking at what data is flowing through the call —
  # `RiskFlowPolicy`'s dynamic, taint-driven check is a separate step
  # the broker runs AFTER these pass, never instead of them. It also
  # excludes the runtime hardening LEGATE.md §8.2 (resolved-address
  # checks) and §8.3 (exec sandboxing) call for: those need a live
  # connection or a real process, so they belong to whatever is
  # actually making one.
  class Grants
    # A static-check outcome. `allowed?` is the broker's fast-path
    # branch; `reason` is a human-readable explanation of a denial,
    # written to end up directly in a denial message rather than
    # requiring the broker to reconstruct one. Denied decisions from
    # different methods below use different reason shapes on purpose
    # (some name a resolved absolute path, some don't) — a caller is
    # expected to display `reason` as-is, not parse it.
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
    getter exec_binaries : Array(String)

    def initialize(@read_roots = [] of String, @write_roots = [] of String,
                   @delete_roots = [] of String, @exec_binaries = [] of String)
    end

    # LEGATE.md §8.1 steps 1–2 (amended check-then-open approach — see
    # §8.1's own rewritten text and the design note on the residual
    # TOCTOU race being accepted, not closed). Resolves `path` with
    # `File.realpath` and confirms the result falls under one of
    # `roots` (also realpath'd, so a symlinked root and a symlinked
    # path compare on equal footing). Which roots array to check is the
    # CALLER's choice — this method doesn't know about read vs write vs
    # delete, it just tests containment against whatever list it's
    # handed, so one implementation serves all three.
    #
    # Only covers a path that already EXISTS. A caller creating a new
    # file has nothing for `File.realpath` to resolve; that case is
    # `check_root_maybe_missing` below.
    def check_root(path : String, roots : Array(String)) : Decision
      return Decision.deny("no roots granted for this operation") if roots.empty?

      real_path = resolve(path)
      return Decision.deny("#{path} does not exist or could not be resolved") unless real_path

      under_root = roots.any? { |root| under?(real_path, root) }

      under_root ? Decision.allow : Decision.deny("#{path} (resolved: #{real_path}) is not under any granted root")
    end

    # The maybe-missing sibling of `check_root` above — same
    # containment question, but for a path that is EXPECTED to possibly
    # not exist yet (LEGATE.md §2.3's "nil for a non-existent path"
    # verbs, e.g. `Legate.stat`; also a write target that has yet to be
    # created). Walks up from `path` to its deepest EXISTING ancestor
    # directory, realpath's *that*, then reconstructs a prospective
    # full path by re-appending the not-yet-resolved trailing
    # components — containment is checked against THAT prospective
    # path, so "outside every granted root" is still a real denial
    # regardless of whether `path` itself happens to exist, while
    # "inside a granted root but missing" is a plain allow, leaving the
    # caller to make its own existence check afterward. The trailing
    # components are compared as literal strings, not further
    # realpath'd (they can't be — they don't exist yet), so a component
    # that turns out to itself be a symlink once created is a gap this
    # method doesn't and can't close; that residual is the same "small
    # enough to accept" reasoning §8.1's own TOCTOU note already makes,
    # not a new exposure this method introduces.
    def check_root_maybe_missing(path : String, roots : Array(String)) : Decision
      return Decision.deny("no roots granted for this operation") if roots.empty?

      ancestor = deepest_existing_ancestor(path)
      return Decision.deny("#{path} has no resolvable ancestor directory") unless ancestor
      real_ancestor, trailing = ancestor
      prospective = trailing.empty? ? real_ancestor : File.join(real_ancestor, File.join(trailing))

      under_root = roots.any? { |root| under_maybe_missing?(prospective, root) }

      under_root ? Decision.allow : Decision.deny("#{path} (prospective: #{prospective}) is not under any granted root")
    end

    # Allowlist membership for an executable, compared resolved-path to
    # resolved-path so a bare name, a relative path and a symlink to
    # the same binary all decide identically.
    def check_binary(binary : String) : Decision
      return Decision.deny("no binaries granted") if exec_binaries.empty?

      real_binary = resolve_binary(binary)
      return Decision.deny("#{binary} could not be resolved to an executable path") unless real_binary

      allowed = exec_binaries.any? { |candidate| resolve(candidate) == real_binary }
      allowed ? Decision.allow : Decision.deny("#{binary} (resolved: #{real_binary}) is not in the granted binary allowlist")
    end

    # `File.realpath` wrapped to return nil instead of raising — every
    # caller above treats "doesn't exist / can't be resolved" as a
    # plain denial reason, not a Crystal-level exception propagating
    # out of a static check. A bare `rescue` deliberately: getting the
    # exact raised type wrong would be worse than catching one type too
    # many in a helper whose only job is "turn failure into nil".
    private def resolve(path : String) : String?
      File.realpath(path)
    rescue
      nil
    end

    # Portable containment test — `real_path` and `root` are both
    # already-realpath'd absolute strings; this decides whether the
    # former sits at-or-under the latter using Crystal's own `Path`
    # (platform-aware: POSIX `/` or Windows `\`/drive letters), NOT
    # hand-rolled `'/'` string concatenation — an earlier version
    # assumed a POSIX separator outright and broke containment on
    # Windows. `Path#relative_to` computes the relative path from
    # `root` to `real_path` by pure path algebra (no filesystem access,
    # no separator assumptions of our own); if the FIRST component of
    # that relative path is `".."`, or the relative path is entirely
    # `".."`-only, `real_path` fell outside `root` and climbed back up
    # instead.
    private def under?(real_path : String, root : String) : Bool
      real_root = resolve(root)
      return false unless real_root

      rel = ::Path.new(real_path).relative_to(::Path.new(real_root))
      return true if rel.to_s == "."
      rel.parts.first? != ".."
    end

    # Same containment test as `under?` just above, but tolerant of a
    # GRANTED ROOT that doesn't exist on disk yet either — added
    # 2026-08-27, once a real script surfaced this exact gap: it
    # granted `write` access to an `output/`-style directory that the
    # script itself creates via `Legate.mkdir`, and THAT `mkdir` call —
    # targeting the granted root path itself, not a file inside it —
    # was denied, because `under?`'s own `resolve(root)` call requires
    # the root to already exist.
    #
    # Only used by `check_root_maybe_missing` above, deliberately —
    # `check_root`'s own strict variant (paths that must ALREADY exist)
    # keeps requiring the root to exist too: a READ grant naming a
    # directory that doesn't exist is basically always a
    # misconfiguration (there's nothing to read from it), unlike a
    # WRITE grant naming a not-yet-created output directory, which is
    # the realistic, worth-supporting case this fix targets.
    #
    # Falls back to the SAME `deepest_existing_ancestor` prospective-
    # path construction `check_root_maybe_missing` already uses for
    # `path`, applied to `root` too — only once the fast, exact
    # `resolve(root)` path fails; the common "root already exists" case
    # costs exactly what it did before.
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

    # Walks `path` upward (via `File.dirname`) until it finds a
    # component that actually exists, then returns that ancestor's OWN
    # realpath alongside the trailing path components (in original
    # order) that were stripped off to get there — the two pieces
    # `check_root_maybe_missing` needs to reconstruct a prospective
    # full path without requiring `path` itself to exist. Returns nil
    # only in the pathological case of no existing ancestor at all (a
    # bogus root, or a relative path climbing past the current working
    # directory's own root).
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

    # `binary` with a directory component (per `Path#parts.size > 1` —
    # portable across POSIX `/` and Windows `\`/drive-letter paths,
    # unlike a plain `binary.includes?('/')` check) is resolved
    # directly, no `PATH` search. A BARE name (`"git"`, no directory
    # component at all) is searched across `PATH` the way a shell
    # resolves `argv[0]`/`CreateProcess` does, checking each directory
    # in order and taking the first existing, executable match. Either
    # way the result is realpath'd before returning, so
    # `check_binary`'s comparison above is always resolved-path-to-
    # resolved-path.
    private def resolve_binary(binary : String) : String?
      return resolve(binary) if ::Path.new(binary).parts.size > 1

      path_env = ENV["PATH"]? || ""
      # `Process::PATH_DELIMITER` — `:` on POSIX, `;` on Windows.
      path_env.split(Process::PATH_DELIMITER).each do |dir|
        next if dir.empty?
        candidate = File.join(dir, binary)
        real = resolve(candidate)
        return real if real && File.file?(real) && File::Info.executable?(real)
      end
      nil
    end
  end
end
