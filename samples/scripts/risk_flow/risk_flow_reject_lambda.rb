require "sample"

SAFE=->(name){delete_file(name)}

def invoke(fn, arg)
  fn.call(arg)
end

begin
  invoke(SAFE, "/etc/passwd")
  puts_args("deleted /etc/passwd (should not happen)")
rescue RiskFlowPolicyError => e
  puts_args("blocked by risk flow policy: #{e.message}")
end
