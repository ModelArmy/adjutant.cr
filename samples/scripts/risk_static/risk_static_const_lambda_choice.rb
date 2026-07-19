require "sample"

class A
  WIPE = ->(name) { delete_file(name) }

  def cleanup(force)
    if force
      WIPE.call("*")
    else
      puts_args()
    end
  end
end

a = A.new
a.cleanup(true)
