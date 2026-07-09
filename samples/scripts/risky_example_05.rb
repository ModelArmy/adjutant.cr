require "sample"

module M
class A
  def cleanup(force)
    if force
      delete_file()
    else
      puts_args()
    end
  end
end
end

i = 0
while i < 3
  fetch_url()
  i += 1
end

M::A.new.cleanup(true)
