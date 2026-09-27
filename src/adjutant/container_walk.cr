module Adjutant
  # Compares and hashes nested Arrays and Hashes without recursing on
  # the native stack, so a script can nest containers to any depth, or
  # make one contain itself, without ending the host process. Equality
  # keeps its to-do list on the heap; hashing looks one level deep.
  module ContainerWalk
    # Pairs of values still to compare.
    alias Pending = Array({Value, Value})
    # Container pairs already met, by identity.
    alias Seen = Set({UInt64, UInt64})

    # What `expand` did with a pair.
    enum Step
      Queued   # a container pair, its members' pairs queued or already met
      Mismatch # a container pair that differs in size or keys
      Leaf     # not a pair of containers of one kind
    end

    # Whether `a` and `b` are equal: Arrays by length and elements,
    # Hashes by keys and values, anything else by the block. A pair of
    # containers met a second time counts as equal, as Ruby's `==`
    # treats a pair it meets while still comparing it, so a
    # self-containing container compares without looping.
    #
    #   ContainerWalk.equal?(a, b) { |x, y| x.raw == y.raw }
    def self.equal?(a : Value, b : Value, & : Value, Value -> Bool) : Bool
      pending = [{a, b}]
      seen = Seen.new
      while pair = pending.pop?
        x, y = pair
        case expand(x.raw, y.raw, pending, seen)
        in .mismatch? then return false
        in .leaf?     then return false unless yield x, y
        in .queued?   then next
        end
      end
      true
    end

    # Queues a container pair's members' pairs, unless the pair was met
    # before.
    private def self.expand(rx : ValueRaw, ry : ValueRaw, pending : Pending, seen : Seen) : Step
      if rx.is_a?(LabeledArray) && ry.is_a?(LabeledArray)
        return Step::Queued unless first_visit?(rx, ry, seen)
        return Step::Mismatch unless rx.size == ry.size
        (rx.size - 1).downto(0) { |i| pending << {rx[i], ry[i]} }
        Step::Queued
      elsif rx.is_a?(LabeledHash) && ry.is_a?(LabeledHash)
        return Step::Queued unless first_visit?(rx, ry, seen)
        return Step::Mismatch unless rx.size == ry.size
        rx.each do |key, value|
          other = ry[key]?
          return Step::Mismatch unless other
          pending << {value, other}
        end
        Step::Queued
      else
        Step::Leaf
      end
    end

    # Records the pair; false if it is one object or was met before.
    private def self.first_visit?(x : Reference, y : Reference, seen : Seen) : Bool
      !x.same?(y) && seen.add?({x.object_id, y.object_id})
    end

    # Feeds `value` into `hasher` without looking inside a nested
    # container: an Array or Hash contributes its kind and size only.
    # Equal containers have equal kinds and sizes, so this stays
    # consistent with `equal?`, and hashing never recurses.
    def self.shallow_hash(value : Value, hasher : Crystal::Hasher) : Crystal::Hasher
      case raw = value.raw
      when LabeledArray
        hasher = 1.hash(hasher)
        raw.size.hash(hasher)
      when LabeledHash
        hasher = 2.hash(hasher)
        raw.size.hash(hasher)
      else
        value.hash(hasher)
      end
    end
  end
end
