require "../../spec_helper"

# Step 4c: the static risk assessment sweep over Legate's verb table.
#
# ## What this file is for, and what it deliberately is not
#
# The agreed shape is **fewer assertions that can actually fail**, not
# coverage. Six tests, each pinning something a plausible future edit
# would silently get wrong. A file of thirty assertions restating what
# the source already says would fail on every legitimate change and
# teach the next reader to update it without reading it.
#
# The thing being defended is narrow but real: a `RiskProfile` is what
# an embedder shows a user BEFORE running a script (DEVELOPMENT.md's
# "Side-effect risk"). It is a promise, and unlike every other Legate
# behaviour it has no runtime consequence — a wrong declaration breaks
# nothing, fails no spec, and misleads silently. `mv` carried
# `DeletesFiles` at `Reversibility::No` for weeks while destroying
# nothing; nothing caught it because nothing could.
#
# ## Why this reads the METHOD TABLE and not the source
#
# The obvious spelling — grep the registration sites — cannot work.
# The eighteen ordinary verbs call `define_native_singleton_method`
# with a literal name, `stat` goes through `Builtins.define_singleton`,
# and five names are produced by a `clobber ? "cp!" : "cp"` ternary at
# registration time. Only the bootstrapped class's own
# `native_singleton_methods` table sees all three shapes, which is
# also the exact view a manifest walker gets.
#
# Note `Sym` is `Adjutant::Sym`, top-level — NOT nested under
# `SymbolTable`, despite `SymbolTable#intern` being what returns one.
# `name_for(id)` is the reverse lookup this file needs.
module Adjutant
  # The bootstrapped `Legate` module's native singleton table, keyed by
  # verb name. Everything below is a different question asked of this.
  private def self.legate_verbs(interp : Interpreter) : Hash(String, NativeCallable)
    legate = interp.get_global("Legate").as_rclass
    table = {} of String => NativeCallable
    legate.native_singleton_methods.each do |sym_id, callable|
      name = interp.symbols.name_for(sym_id)
      raise "verb symbol #{sym_id} has no name — symbol table and method table disagree" unless name
      table[name] = callable
    end
    table
  end

  describe "Legate's static risk surface" do
    # ASSERTION 1 — the verb table itself.
    #
    # Whole-set `should eq` rather than membership checks, and this is
    # the load-bearing choice: a membership check cannot fail when a
    # verb is ADDED, so a new verb would slip in declaring whatever it
    # liked and no assertion below would ever look at it. Comparing
    # the full sorted list means a new verb breaks this test first,
    # and the fix is to add it here — which forces someone to state
    # its effects in assertion 2 as well.
    #
    # The count is asserted separately from the names even though it
    # is implied by them, because the failure messages are different
    # and the count one is the clearer signal when a whole bootstrap
    # call goes missing.
    it "registers exactly the 19 verbs the spec's §0 records as built" do
      interp, _ = make_interp
      verbs = legate_verbs(interp)

      verbs.size.should eq 19
      verbs.keys.sort.should eq [
        "append", "bytes", "cp", "cp!", "fetch", "grep", "lines", "list",
        "mkdir", "mv", "mv!", "read", "records", "rm", "rmdir", "rmdir!",
        "stat", "write", "write!",
      ]
    end

    # ASSERTION 2 — the full effect map, whole sets, no membership.
    #
    # `should eq` on the entire hash, for the same reason as above and
    # one more: a membership check (`effects.should contain
    # DeletesFiles`) passes just as happily when a verb declares MORE
    # than it should. Over-declaration is the likelier drift — someone
    # adds `DeletesFiles` to `mv` "to be safe" — and it is not safe.
    # It makes the manifest cry wolf, and a manifest that overstates
    # gets ignored exactly like one that understates.
    #
    # Read this map as the answer to "what does this verb do to the
    # world", never "what is it allowed to do". Those are different
    # questions with different vocabularies (`Effect` vs `Authority`),
    # and `mv` below is the worked example: it takes BOTH `Delete` and
    # `Write` authority while declaring `MovesFiles` alone.
    it "declares exactly these effects per verb" do
      interp, _ = make_interp
      effects = legate_verbs(interp).transform_values(&.risk.effects)

      effects.should eq({
        # Reads.
        "read"    => Set{Effect::ReadsFiles},
        "stat"    => Set{Effect::ReadsFiles},
        "list"    => Set{Effect::ReadsFiles},
        "grep"    => Set{Effect::ReadsFiles},
        "lines"   => Set{Effect::ReadsFiles},
        "bytes"   => Set{Effect::ReadsFiles},
        "records" => Set{Effect::ReadsFiles},
        # Writes. The bangs add `DeletesFiles` for the destination
        # they replace — a real loss of content the script never
        # named as a target.
        "write"  => Set{Effect::WritesFiles},
        "write!" => Set{Effect::WritesFiles, Effect::DeletesFiles},
        "append" => Set{Effect::WritesFiles},
        "mkdir"  => Set{Effect::WritesFiles},
        "cp"     => Set{Effect::ReadsFiles, Effect::WritesFiles},
        "cp!"    => Set{Effect::ReadsFiles, Effect::WritesFiles, Effect::DeletesFiles},
        # Deletes. `mv` is the asymmetry: `MovesFiles` ALONE, because
        # a rename preserves the information and the cross-device
        # fallback is ordered copy-then-delete.
        "rm"     => Set{Effect::DeletesFiles},
        "rmdir"  => Set{Effect::DeletesFiles},
        "rmdir!" => Set{Effect::DeletesFiles, Effect::Recursive},
        "mv"     => Set{Effect::MovesFiles},
        "mv!"    => Set{Effect::MovesFiles, Effect::DeletesFiles},
        # Net.
        "fetch" => Set{Effect::NetworkEgress},
      })
    end

    # ASSERTION 3 — an INVARIANT rather than a table.
    #
    # Unlike the two above, this one keeps holding as verbs are added,
    # which is why it is worth having alongside them: it is the rule
    # the maps are instances of. `RiskProfile`'s own constructor
    # already refuses `No`/`Warning` on an EFFECT-LESS profile; this
    # is the other direction, which nothing enforces — a profile that
    # destroys something while claiming to be reversible.
    #
    # `MovesFiles` is deliberately absent from the trigger set. That
    # is the entire point of the effect existing: a move is
    # destructive-sounding and is not destructive.
    it "never declares a destructive verb reversible" do
      interp, _ = make_interp
      offenders = legate_verbs(interp).select do |_, callable|
        callable.risk.effects.includes?(Effect::DeletesFiles) &&
          callable.risk.reversible == Reversibility::Yes
      end

      offenders.keys.should be_empty
    end

    # ASSERTION 4 — the drift the two-field design risks.
    #
    # `NativeCallable` carries `risk` (effects) and `authorities`
    # deliberately underived from each other, because a mapping table
    # between them would drift (a move needs Delete authority while
    # destroying nothing). The cost of that choice is that a
    # registration can declare one and forget the other.
    #
    # Today the answer is that NO Legate verb declares `authorities`
    # at all: enforcement runs entirely through `broker.authorize`'s
    # explicit `declare_sensitivity` path, so `check_risk_flow`'s
    # automatic path is inert for every Legate call. That is a real
    # design position, not an oversight — but it is one nobody has
    # revisited, and if a verb starts declaring authorities it should
    # be a decision rather than an accident. This test fails EITHER
    # way: if a verb gains authorities, or if the empty-set assumption
    # stops holding uniformly.
    it "declares authorities on all verbs or none — currently none" do
      interp, _ = make_interp
      with_authorities = legate_verbs(interp).select { |_, c| !c.authorities.empty? }

      with_authorities.keys.sort.should eq [] of String
    end

    # ASSERTION 5 — end to end, through the real walker.
    #
    # The four above read the method table directly, which proves the
    # declarations are right but not that anything can SEE them. This
    # one goes through the actual static pass a host program runs:
    # parse, walk, summarize. `Legate.fetch` specifically, because a
    # `ConstPath`-shaped receiver resolving to a native singleton is
    # the exact path that was broken once before (see
    # risk_walker_const_path_singletons_spec.cr) and is how EVERY
    # Legate call is written. `rmdir!` alongside it because a bang
    # method name reaching the walker at all is new as of the verb
    # split.
    #
    # Two statements in SEQUENCE, deliberately — see the next test for
    # what a branch would have done instead.
    it "surfaces verb effects through a real RiskWalker pass on ConstPath receivers" do
      interp, _ = make_interp
      walker = RiskWalker.new(interp)
      body = Parser.new(<<-RUBY).parse
        Legate.fetch("https://example.com")
        Legate.rmdir!("/tmp/scratch")
      RUBY

      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.effects.should eq Set{Effect::NetworkEgress, Effect::DeletesFiles, Effect::Recursive}
      summary.severity.should eq Severity::Warning
      summary.reversible.should eq Reversibility::No
    end

    # ASSERTION 6 — what a BRANCH reports, which is not what a
    # sequence reports.
    #
    # Pinned because the first draft of assertion 5 above got this
    # wrong, and the mistake is an easy one to make twice:
    # `summarize_choice` (risk_aggregator.cr) takes `max_by { rank }`
    # — the single WORST branch — not the union across branches. A
    # `RiskChoice` means exactly one branch runs, so unioning would
    # claim a script does both things when it can only ever do one.
    #
    # The consequence is worth stating, since it is a real property of
    # the manifest an embedder shows a user and not an implementation
    # detail: **effects belonging only to a losing branch do not
    # appear at all.** Below, the script can delete a whole tree, and
    # the summary says `NetworkEgress`. Both branches rank equally
    # (`No`/`Warning`), so the tie goes to the first.
    #
    # Whether that is the right trade is a live question — the ranking
    # is by severity and reversibility, which are CONCLUSIONS, so
    # effects get carried along by whichever branch won on other
    # grounds rather than being reasoned about themselves. This test
    # documents the behaviour rather than endorsing it; if it ever
    # changes deliberately, this is where the change announces itself.
    it "reports a branch's worst case, not the union across branches" do
      interp, _ = make_interp
      walker = RiskWalker.new(interp)
      body = Parser.new(<<-RUBY).parse
        if ENV_FLAG
          Legate.fetch("https://example.com")
        else
          Legate.rmdir!("/tmp/scratch")
        end
      RUBY

      summary = RiskAggregator.summarize(walker.walk_body(body))
      summary.effects.should eq Set{Effect::NetworkEgress}
      summary.severity.should eq Severity::Warning
    end
  end
end
