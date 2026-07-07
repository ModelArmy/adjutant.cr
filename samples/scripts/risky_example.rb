require "sample"

def cleanup(force)
  if force
    delete_file()
  else
    puts_args()
  end
end

i = 0
while i < 3
  fetch_url()
  i += 1
end

cleanup(true)
