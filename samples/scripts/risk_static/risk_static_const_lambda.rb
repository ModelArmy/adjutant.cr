require "sample"

class A
  WIPE = ->(name) { delete_file(name) }

  def cleanup
    WIPE.call("one")
  end
end

a = A.new
a.cleanup
