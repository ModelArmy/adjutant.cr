# Read by samples/worker_host.cr. Run from the repository root:
#
#   bin/debug/worker_host samples/scripts/worker/read_secret.rb
#
# The host's policy marks any path containing "secret" as high
# sensitivity and asks before such a file is read.

puts "Reading the note..."
puts Legate.read("samples/scripts/worker/note.txt")

puts "Reading the secret..."
begin
  puts Legate.read("samples/scripts/worker/secret.txt")
rescue RiskFlowRejectedError
  puts "Refused; carrying on without it."
end

"done"
