require "json"
require "./risk_flow_label"

module Adjutant
  # One label join during execution, recorded so audit and debugging
  # can see how a label was built; two values with the same label can
  # get there by different paths. See research/IFC_DESIGN.md, "Risk
  # flow log".
  struct RiskFlowEvent
    include JSON::Serializable

    getter op : String                    # VM operation that triggered the join, e.g. "Add", "SetIndex"
    getter inputs : Array(RiskFlowLabel?) # labels of the values that went into the join
    getter result : RiskFlowLabel?        # the label produced by the join
    getter line : Int32                   # source line in the frame where the op executed

    def initialize(@op : String, @inputs : Array(RiskFlowLabel?), @result : RiskFlowLabel?, @line : Int32)
    end
  end

  # Every label join during a run, in order, append-only. Owned by the
  # Interpreter, so it outlives each VM. Disabled unless built with
  # `enabled: true`, in which case `record` is a no-op.
  class RiskFlowLog
    include JSON::Serializable

    getter events : Array(RiskFlowEvent)
    getter? enabled : Bool

    def initialize(@enabled : Bool = false)
      @events = [] of RiskFlowEvent
    end

    # Appends an event if enabled; call sites needn't check.
    def record(op : String, inputs : Array(RiskFlowLabel?), result : RiskFlowLabel?, line : Int32) : Nil
      return unless enabled?
      @events << RiskFlowEvent.new(op, inputs, result, line)
    end

    def clear : Nil
      @events.clear
    end
  end
end
