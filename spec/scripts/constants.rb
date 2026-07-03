require "assert"

MYCONST = 1

class A
  MYCONST = 3

  class B
    MYCONST = 5

    def b_const
      MYCONST
    end

    def a_const
      A::MYCONST
    end

    def top_a_const
      ::A::MYCONST
    end

    def root_const
      ::MYCONST
    end

    class A
      MYCONST = 7

      def b_const
        B::MYCONST
      end

      def top_a_const
        ::A::MYCONST
      end

      def a_const
        MYCONST
      end

      def root_const
        ::MYCONST
      end
    end

  end

  def b_const
    B::MYCONST
  end

  def a_const
    MYCONST
  end

  def root_const
    ::MYCONST
  end

end


assert_equal(A::MYCONST, 3)
assert_equal(A::B::MYCONST, 5)
assert_equal(A::B::A::MYCONST, 7)
assert_equal(MYCONST, 1)
assert_equal(::MYCONST, 1)

assert_equal(A.new.a_const, 3)
assert_equal(A.new.b_const, 5)
assert_equal(A.new.root_const, 1)

assert_equal(A::B.new.a_const, 7)
assert_equal(A::B.new.top_a_const, 3)
assert_equal(A::B.new.b_const, 5)
assert_equal(A::B.new.root_const, 1)

assert_equal(A::B::A.new.a_const, 7)
assert_equal(A::B::A.new.top_a_const, 3)
assert_equal(A::B::A.new.b_const, 5)
assert_equal(A::B::A.new.root_const, 1)
