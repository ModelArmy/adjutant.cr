require "sample"

class A
  def cleanup(wiper)
    wiper.call("one")
  end

end

a = A.new
a.cleanup(->() { delete_file }  )

a = A.new
a.cleanup(->() { delete_file() } )
