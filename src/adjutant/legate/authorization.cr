require "./grants"

module Adjutant
  module Legate
    # Reopens Grants (grants.cr) to add the pure STATIC checks a
    # verb's broker call goes through before anything else happens —
    # the roots/hosts/binaries allowlist half of §8, kept separate
    # from grants.cr's own config-parsing concern so each file stays
    # about one thing. `RiskFlowPolicy`'s dynamic, taint-driven check
    # is a completely separate step the broker (4c) runs AFTER these
    # pass, never instead of them — see the design conversation this
    # session had on how Grants and RiskFlowPolicy relate.
    #
    # Deliberately narrow: these three methods cover exactly what a
    # Grants config can decide on its own (does this belong to an
    # allowed root/host/binary set), not the runtime hardening §8.2
    # (SSRF/DNS-range checks, which need a real network call) and
    # §8.3 (exec sandboxing) call for, nor §8.1's own step 3
    # (immediately-before-use re-check right at the open() call) —
    # those need a concrete verb to attach to and land with the verb
    # surface in step 5.
    class Grants
      # A static-check outcome. `allowed?` is the broker's fast-path
      # branch; `reason` is a human-readable explanation of a denial,
      # written to end up directly in a `Legate::Denied` message
      # rather than requiring the broker to reconstruct one. Denied
      # decisions from different methods below use different reason
      # shapes on purpose (some name a resolved absolute path, some
      # don't) — the broker is expected to display `reason` as-is, not
      # parse it.
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

      # §8.1 steps 1–2 (amended check-then-open approach — see
      # LEGATE.md §8.1's own rewritten text and this session's design
      # note on the residual TOCTOU race being accepted, not closed).
      # Resolves `path` with `File.realpath` and confirms the result
      # falls under one of `roots` (also realpath'd, so a symlinked
      # root and a symlinked path compare on equal footing). Which
      # roots array to check is the CALLER's choice — this method
      # doesn't know about `read` vs `write` vs `delete`, it just
      # tests containment against whatever list it's handed, so one
      # implementation serves all three grant categories.
      #
      # Only covers a path that already EXISTS. A verb creating a new
      # file (e.g. `write` to a path that doesn't exist yet) has
      # nothing for `File.realpath` to resolve — that case needs the
      # verb to realpath the PARENT directory instead and is properly
      # step 5's problem (it's specific to what the verb is actually
      # doing), not this general-purpose check's.
      def check_root(path : String, roots : Array(String)) : Decision
        return Decision.deny("no roots granted for this operation") if roots.empty?

        real_path = resolve(path)
        return Decision.deny("#{path} does not exist or could not be resolved") unless real_path

        under_root = roots.any? { |root| under?(real_path, root) }

        under_root ? Decision.allow : Decision.deny("#{path} (resolved: #{real_path}) is not under any granted root")
      end

      # The maybe-missing sibling of `check_root` above — same
      # containment question, but for a path that is EXPECTED to
      # possibly not exist yet (LEGATE.md §2.3's "nil for a
      # non-existent path" verbs, e.g. `Legate.stat`; also the write-
      # target gap `check_root`'s own comment flagged as deferred
      # here). Walks up from `path` to its deepest EXISTING ancestor
      # directory, realpath's *that*, then reconstructs a prospective
      # full path by re-appending the not-yet-resolved trailing
      # components — containment is checked against THAT prospective
      # path, so "outside every granted root" is still a real denial
      # regardless of whether `path` itself happens to exist, while
      # "inside a granted root but missing" is a plain allow, leaving
      # the caller to make its own existence check afterward. The
      # trailing components are compared as literal strings, not
      # further realpath'd (they can't be — they don't exist yet), so
      # a component that turns out to itself be a symlink once
      # created is a gap this method doesn't and can't close; that
      # residual is the same "small enough to accept, given Legate's
      # threat model" reasoning §8.1's own TOCTOU note already makes,
      # not a new exposure this method introduces.
      def check_root_maybe_missing(path : String, roots : Array(String)) : Decision
        return Decision.deny("no roots granted for this operation") if roots.empty?

        ancestor = deepest_existing_ancestor(path)
        return Decision.deny("#{path} has no resolvable ancestor directory") unless ancestor
        real_ancestor, trailing = ancestor
        prospective = trailing.empty? ? real_ancestor : File.join(real_ancestor, File.join(trailing))

        under_root = roots.any? { |root| under?(prospective, root) }

        under_root ? Decision.allow : Decision.deny("#{path} (prospective: #{prospective}) is not under any granted root")
      end

      # Allowlist membership only — exact string match against
      # `net_hosts`. No wildcard/subdomain matching (§7's own example
      # lists exact hostnames, not patterns) and no SSRF/DNS-resolved-
      # address-range check (§8.2) — that needs the actual connection
      # attempt's resolved address, which only exists once a `net`
      # verb is mid-call, so it's deferred there.
      def check_host(host : String) : Decision
        return Decision.deny("no hosts granted") if net_hosts.empty?
        net_hosts.includes?(host) ? Decision.allow : Decision.deny("#{host} is not in the granted host allowlist")
      end

      # Resolves `binary` to an absolute path — a bare name (no `/`)
      # is searched for on `PATH`, same as a shell would; anything
      # containing `/` is realpath'd directly — then compares that
      # resolution against `exec_binaries` (also realpath'd, so an
      # allowlist entry that's itself a symlink still matches).
      # Comparing POST-resolution on both sides is the point: it's
      # what stops a `PATH` trick or a symlinked allowlist entry from
      # producing a false allow or a false deny.
      def check_binary(binary : String) : Decision
        return Decision.deny("no binaries granted") if exec_binaries.empty?

        real_binary = resolve_binary(binary)
        return Decision.deny("#{binary} could not be resolved to an executable path") unless real_binary

        allowed = exec_binaries.any? { |candidate| resolve(candidate) == real_binary }
        allowed ? Decision.allow : Decision.deny("#{binary} (resolved: #{real_binary}) is not in the granted binary allowlist")
      end

      # `File.realpath` wrapped to return nil instead of raising —
      # every caller above treats "doesn't exist / can't be resolved"
      # as a plain denial reason, not a Crystal-level exception
      # propagating out of a static check. NOT independently verified
      # against a live toolchain — `File.realpath`'s exact raised
      # exception type on a missing path is written from recollection
      # (`File::NotFoundError` broadened to a bare `rescue` here
      # specifically because getting the exact type wrong would be
      # worse than catching one exception type too many in a helper
      # whose only job is "turn failure into nil").
      private def resolve(path : String) : String?
        File.realpath(path)
      rescue
        nil
      end

      # Portable containment test — `real_path` and `root` are both
      # already-realpath'd absolute strings; this decides whether the
      # former sits at-or-under the latter using Crystal's own `Path`
      # (platform-aware: POSIX `/` or Windows `\`/drive letters, per
      # https://crystal-lang.org/api/1.21.0/Path.html), NOT hand-
      # rolled `'/'` string concatenation — the previous version of
      # this check assumed a POSIX separator outright and broke
      # containment on Windows. `Path#relative_to` computes the
      # relative path from `root` to `real_path` by pure path algebra
      # (no filesystem access, no separator assumptions of our own);
      # if the FIRST component of that relative path is `".."`, or the
      # relative path is entirely `".."`-only, `real_path` fell
      # outside `root` and climbed back up instead. NOT independently
      # verified against a live toolchain — `Path#relative_to`'s exact
      # return shape for an already-equal or already-descendant pair
      # is written from the API docs, not a compiled check.
      private def under?(real_path : String, root : String) : Bool
        real_root = resolve(root)
        return false unless real_root

        rel = ::Path.new(real_path).relative_to(::Path.new(real_root))
        return true if rel.to_s == "."
        rel.parts.first? != ".."
      end

      # Walks `path` upward (via `File.dirname`) until it finds a
      # component that actually exists, then returns that ancestor's
      # OWN realpath alongside the trailing path components (in
      # original order) that were stripped off to get there — the two
      # pieces `check_root_maybe_missing` needs to reconstruct a
      # prospective full path without requiring `path` itself to
      # exist. Returns nil only in the pathological case of no
      # existing ancestor at all (a bogus root, or a relative path
      # climbing past the current working directory's own root).
      private def deepest_existing_ancestor(path : String) : {String, Array(String)}?
        trailing = [] of String
        current = path
        loop do
          if real = resolve(current)
            return {real, trailing}
          end
          parent = File.dirname(current)
          return nil if parent == current
          trailing.unshift(File.basename(current))
          current = parent
        end
      end

      # `binary` with a directory component (per `Path#parts.size > 1`
      # — portable across POSIX `/` and Windows `\`/drive-letter
      # paths, unlike the previous plain `binary.includes?('/')`
      # check) is resolved directly, no `PATH` search. A BARE name
      # (`"git"`, no directory component at all) is searched across
      # `PATH` the way a shell resolves `argv[0]`/`CreateProcess`
      # does, checking each directory in order and taking the first
      # existing, executable match. Either way the result is
      # realpath'd before returning, so `check_binary`'s comparison
      # above is always resolved-path-to-resolved-path.
      private def resolve_binary(binary : String) : String?
        return resolve(binary) if ::Path.new(binary).parts.size > 1

        path_env = ENV["PATH"]? || ""
        # `Process::PATH_DELIMITER` — `:` on POSIX, `;` on Windows.
        # NOT independently verified against a live toolchain; this
        # constant's exact name is written from recollection of
        # Crystal's own cross-platform PATH-search handling for
        # Process.exec, which has the identical problem to solve.
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
end
