require "./adjutant/security_label"
require "./adjutant/value"
require "./adjutant/token"
require "./adjutant/lexer"
require "./adjutant/ast"
require "./adjutant/parser"
require "./adjutant/symbol_table"
require "./adjutant/bytecode"
require "./adjutant/compiler"

module Adjutant
  # Read this at compile time from shard.yml one day
  VERSION    = {{ `shards version #{__DIR__}`.chomp.stringify }}
  PRERELEASE = VERSION.match(/^\d+\.\d+\.\d+$/).nil?
end
