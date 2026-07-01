require "./adjutant/security_label"
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

module Adjutant
  VERSION    = {{ `shards version #{__DIR__}`.chomp.stringify }}
  PRERELEASE = true
end
