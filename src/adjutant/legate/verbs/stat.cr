require "../broker"
require "../stat"
require "../helpers"
require "../../native_call_context"
require "../../builtins/time"

module Adjutant
  module Legate
    module Verbs
      # `Legate.stat(path) -> Legate::Stat | nil` — LEGATE.md §4.1.
      # The first real Legate verb; establishes the shape every later
      # read-grant verb (`read`, `list`, `grep`) reuses: extract the
      # raw path string via a real `#to_s` dispatch (so both a bare
      # String and a `Legate::Path` argument work identically, and
      # either one's taint label survives), call the broker, then do
      # the actual filesystem work.
      module Stat
        def self.bootstrap(interp : Interpreter, legate : RubyClass, broker : Broker) : Nil
          stat_cls = Helpers.fetch(legate, interp, "Stat")

          # `risk: ReadsFiles` here is the AUTOMATIC, label-driven
          # check (VM#check_risk_flow) — complementary to, not a
          # duplicate of, `broker.authorize_read`'s own
          # `declare_sensitivity` call below. This one fires when the
          # ARGUMENT arrives already labeled (e.g. a path string built
          # from something a previous tainted read produced);
          # `declare_sensitivity` fires on the path's own literal
          # content regardless of whether it carries an incoming
          # label at all. A verb touching files needs both, same as
          # every risk-tagged native method elsewhere in this
          # codebase — this is not a Legate-specific pattern.
          Builtins.define_singleton(legate, interp, "stat", risk: RiskProfile.new(effects: Set{Effect::ReadsFiles})) do |args, _blk, ncc|
            path_val = args[1]? || Value.nil_value
            str_val = ncc.call_method(path_val, "to_s", [] of Value)
            raw = str_val.as_string
            label = str_val.label

            # §2.3/§4.1: nil for a non-existent path is the documented
            # outcome — but a path outside every granted root is still
            # a real denial regardless of whether it happens to exist,
            # so authorization runs BEFORE the existence check, via
            # `allow_missing: true` (check_root_maybe_missing,
            # authorization.cr) rather than the plain check every
            # other read-grant verb uses. Without this, ANY
            # non-existent path would be denied as "does not exist"
            # before Grants ever answered the real containment
            # question — collapsing "outside your roots" (a real
            # refusal) and "inside your roots but missing" (a plain
            # nil) into the same fatal error, exactly the distinction
            # §2.3 exists to preserve.
            #
            # `RiskFlowLabel.join` here — added 2026-08-26, fixing a
            # real gap this session's audit found: `broker.authorize_
            # read` now RETURNS the label RiskFlowPolicy itself just
            # resolved for `raw` (built from whatever `sensitivity_
            # for(File, raw)` came back as, or `nil` if the policy
            # doesn't consider this path sensitive at all — see
            # `Broker#authorize`/`VM#declare_sensitivity`'s own
            # comments). Previously this return value was silently
            # discarded — the READ was correctly gated by policy, but
            # the RETURNED VALUE carried no taint reflecting that,
            # so a later sink check (e.g. LEGATE.md §7.6's argv-taint
            # rule) could never catch a sensitive file's content
            # flowing somewhere it shouldn't. `join`, not plain
            # overwrite, because `label` (the PATH ARGUMENT's own,
            # pre-existing taint — e.g. a path built from a prior
            # tainted read) must survive too; the two are independent
            # provenance facts, not alternatives.
            label = RiskFlowLabel.join(label, broker.authorize_read(raw, ncc, allow_missing: true))

            info = File.info?(raw, follow_symlinks: false)
            next Value.nil_value unless info

            Legate::Stat.build(interp, stat_cls, type_of(info), info.size, mtime_of(interp, info), mode_of(info), label)
          end
        end

        # §5.2's `:file | :dir | :symlink | :other` — deliberately
        # NOT following the last symlink hop (`follow_symlinks:
        # false` above): a stat'd symlink should be REPORTED as a
        # symlink, matching `Legate.list`'s own documented "symlinks
        # reported, not followed" (§4.1) for the same reason.
        # Authorization (broker.authorize_read, above) still fully
        # resolves symlinks for CONTAINMENT — the two checks
        # deliberately look at the path differently, for different
        # reasons (security boundary vs. what the script is told).
        private def self.type_of(info : File::Info) : Symbol
          case info.type
          when File::Type::File      then :file
          when File::Type::Directory then :dir
          when File::Type::Symlink   then :symlink
          else                            :other
          end
        end

        # NOT independently verified against a live toolchain —
        # `File::Info#permissions`'s exact Crystal type
        # (`File::Permissions`, presumed to expose the raw mode via
        # `#value`) is written from recollection.
        private def self.mode_of(info : File::Info) : Int32
          info.permissions.value.to_i32
        end

        # `mtime` is unlabeled here deliberately — see this file's own
        # `label` handling above: the label seeded onto the WHOLE
        # `Stat` object comes from the queried path's own taint
        # (matching Stat.build's own top comment on how it threads
        # `label` through), not from anything specific to the
        # modification time value itself.
        private def self.mtime_of(interp : Interpreter, info : File::Info) : Value
          time_cls = interp.get_global("Time").as_rclass
          Value.robject(TimeObject.new(time_cls, info.modification_time))
        end
      end
    end
  end
end
