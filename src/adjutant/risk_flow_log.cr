require "json"
require "./risk_flow_label"

module Adjutant
  # One join performed during execution — records enough to reconstruct
  # how a label was built up, for post-hoc audit/troubleshooting. See
  # research/IFC_DESIGN.md's "Risk flow log" section: live risk flow checks only
  # need the current joined label, but audit and debugging need the
  # history of how that label was built, since two values that end up
  # with the same joined label can have arrived there via different
  # paths.
  #
  # `inputs`/`result` use RiskFlowLabel? directly (not raw tag arrays) so
  # a RiskFlowEvent round-trips through the same JSON shape as a bare label
  # elsewhere in the system — no separate serialization format to keep in
  # sync.
  struct RiskFlowEvent
    include JSON::Serializable

    getter op : String                    # VM operation that triggered the join, e.g. "Add", "SetIndex"
    getter inputs : Array(RiskFlowLabel?) # labels of the values that went into the join
    getter result : RiskFlowLabel?        # the label produced by the join
    getter line : Int32                   # source line in the frame where the op executed

    def initialize(@op : String, @inputs : Array(RiskFlowLabel?), @result : RiskFlowLabel?, @line : Int32)
    end
  end

  # Append-only record of every label join performed during one script
  # execution. Owned by the Interpreter (survives across VM.run calls
  # made through it, unlike the VM itself which is fresh per run — see
  # Interpreter#make_vm) so a script's complete flow history can be
  # inspected after execution finishes, for troubleshooting the IFC
  # implementation itself or as an audit record.
  #
  # Disabled by default (see #enabled?, set via `enabled: true` at
  # construction) — this is the hook point for the future "enable/disable
  # flow tracking per execution" config (research/IFC_DESIGN.md): when
  # disabled, #record is a no-op, so join sites can call it unconditionally
  # without branching on the flag themselves.
  class RiskFlowLog
    include JSON::Serializable

    getter events : Array(RiskFlowEvent)
    getter? enabled : Bool

    def initialize(@enabled : Bool = false)
      @events = [] of RiskFlowEvent
    end

    # Append an event, unless logging is disabled. Call sites (join
    # points in the VM) can call this unconditionally — the enabled
    # check lives here, once, rather than being duplicated at every
    # call site.
    def record(op : String, inputs : Array(RiskFlowLabel?), result : RiskFlowLabel?, line : Int32) : Nil
      return unless enabled?
      @events << RiskFlowEvent.new(op, inputs, result, line)
    end

    def clear : Nil
      @events.clear
    end
  end
end
