require "./adjutant/risk_flow_label"
require "./adjutant/risk_flow_log"
require "./adjutant/labeled_container"
require "./adjutant/risk_flow_policy"
require "./adjutant/symbol_table"
require "./adjutant/value"
require "./adjutant/ruby_class"
require "./adjutant/token"
require "./adjutant/lexer"
require "./adjutant/ast"
require "./adjutant/parser"
require "./adjutant/bytecode"
require "./adjutant/compiler"
require "./adjutant/effect_handler"
require "./adjutant/module_registry"
require "./adjutant/vm"
require "./adjutant/interpreter"
require "./adjutant/builtins"
require "./adjutant/risk_node"
require "./adjutant/risk_aggregator"
require "./adjutant/type_hint"
require "./adjutant/type_inference"
require "./adjutant/risk_walker"

module Adjutant
  VERSION    = {{ `shards version #{__DIR__}`.chomp.stringify }}
  PRERELEASE = true
end
