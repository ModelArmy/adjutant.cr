require "yaml"

module Adjutant
  # A policy document that can't be loaded, naming where it went wrong
  # as a dotted path such as `risk_flow.rules[2].subject`. POLICY.md §1
  # lists what raises it.
  class InvalidPolicyError < ArgumentError
    def initialize(message : String, cause : Exception? = nil)
      super(message)
      @cause = cause
    end
  end

  # The size literals a policy's limits use ("8MiB", "512MiB").
  module SizeLiteral
    SIZE_RE = /\A(\d+)\s*(B|KiB|MiB|GiB)?\z/

    # Binary units (KiB, MiB, GiB); a bare integer is bytes. Raises
    # ArgumentError for anything else.
    def self.bytes(str : String) : Int64
      bytes?(str) || raise ArgumentError.new("invalid size literal #{str.inspect} (want e.g. \"8MiB\", \"512MiB\", \"4GiB\", or a bare byte count)")
    end

    # `bytes`, or nil for anything it would refuse.
    def self.bytes?(str : String) : Int64?
      m = SIZE_RE.match(str.strip)
      return unless m
      n = m[1].to_i64?
      return unless n
      case m[2]?
      when "KiB" then n * 1024_i64
      when "MiB" then n * 1024_i64 ** 2
      when "GiB" then n * 1024_i64 ** 3
      else            n
      end
    end
  end

  # The duration literals a policy's limits use ("300s").
  module DurationLiteral
    DURATION_RE = /\A(\d+)s\z/

    # Seconds only ("300s"). Raises ArgumentError for anything else.
    def self.seconds(str : String) : Int32
      seconds?(str) || raise ArgumentError.new("invalid duration literal #{str.inspect} (want e.g. \"300s\")")
    end

    # `seconds`, or nil for anything it would refuse.
    def self.seconds?(str : String) : Int32?
      DURATION_RE.match(str.strip).try(&.[1].to_i32?)
    end
  end

  # Strict reads from a parsed policy document. Each raises
  # InvalidPolicyError naming the offending path. A key that is absent,
  # or present with no value (`limits:` alone), reads as not given.
  module YamlPolicy
    alias Mapping = Hash(YAML::Any, YAML::Any)

    # `node` as a mapping whose keys are all in `allowed`.
    def self.mapping(node : YAML::Any, path : String, allowed : Enumerable(String)) : Mapping
      hash = node.as_h?
      raise invalid(path, "must be a mapping, got #{describe(node)}") unless hash
      hash.each_key do |key|
        name = key.as_s?
        unless name && allowed.includes?(name)
          raise invalid(path, "has an unknown key #{key.raw.inspect}; expected one of #{allowed.join(", ")}")
        end
      end
      hash
    end

    # The value under `key`, or nil if not given.
    def self.value(parent : Mapping?, key : String) : YAML::Any?
      node = parent.try(&.[YAML::Any.new(key)]?)
      node unless node.nil? || node.raw.nil?
    end

    # The mapping under `key`, checked against `allowed`, or nil if
    # not given.
    def self.section(parent : Mapping?, key : String, path : String, allowed : Enumerable(String)) : Mapping?
      node = value(parent, key)
      mapping(node, path, allowed) if node
    end

    # The entries of `parent` whose keys are in `keys`, or nil if there
    # are none.
    def self.subset(parent : Mapping?, keys : Enumerable(String)) : Mapping?
      return unless parent
      picked = parent.select { |key, _| keys.includes?(key.as_s) }
      picked unless picked.empty?
    end

    # The list under `key`, or empty if not given.
    def self.list(parent : Mapping?, key : String, path : String) : Array(YAML::Any)
      node = value(parent, key)
      return [] of YAML::Any unless node
      node.as_a? || raise invalid(path, "must be a list, got #{describe(node)}")
    end

    # The list of strings under `key`, or empty if not given.
    def self.strings(parent : Mapping?, key : String, path : String) : Array(String)
      list(parent, key, path).map do |entry|
        entry.as_s? || raise invalid(path, "must list strings, got #{describe(entry)}")
      end
    end

    # A positive byte count, as a YAML integer or a size literal
    # ("8MiB", "1048576"), or nil if not given.
    def self.size(parent : Mapping?, key : String) : Int64?
      node = value(parent, key)
      return unless node
      bytes = node.as_i64? || node.as_s?.try { |str| SizeLiteral.bytes?(str) }
      raise invalid("limits.#{key}", "must be a size such as 8MiB or a byte count, got #{describe(node)}") unless bytes
      raise invalid("limits.#{key}", "must be positive, got #{bytes}") unless bytes > 0
      bytes
    end

    # A positive number of seconds, as a YAML integer or a duration
    # literal ("300s"), or nil if not given.
    def self.seconds(parent : Mapping?, key : String) : Int32?
      node = value(parent, key)
      return unless node
      n = node.as_i64? || node.as_s?.try { |str| DurationLiteral.seconds?(str).try(&.to_i64) }
      raise invalid("limits.#{key}", "must be a duration such as 300s, got #{describe(node)}") unless n
      positive_int32!("limits.#{key}", n)
    end

    # A positive count, as a YAML integer, or nil if not given.
    def self.count(parent : Mapping?, key : String) : Int32?
      node = value(parent, key)
      return unless node
      n = node.as_i64?
      raise invalid("limits.#{key}", "must be a whole number, got #{describe(node)}") unless n
      positive_int32!("limits.#{key}", n)
    end

    # Any whole number that fits an Int32, or nil if not given.
    def self.integer(parent : Mapping?, key : String, path : String) : Int32?
      node = value(parent, key)
      return unless node
      n = node.as_i64?
      raise invalid(path, "must be a whole number, got #{describe(node)}") unless n
      raise invalid(path, "is out of range: #{n}") if n < Int32::MIN || n > Int32::MAX
      n.to_i32
    end

    # A member of the enum `type`, written as its lowercase name
    # (`high`, `user_input`), or nil if not given.
    def self.choice(parent : Mapping?, key : String, path : String, type : T.class) : T? forall T
      node = value(parent, key)
      return unless node
      name = node.as_s?
      found = type.values.find { |member| member.to_s.underscore == name }
      found || raise invalid(path, "must be one of #{type.values.join(", ", &.to_s.underscore)}, got #{describe(node)}")
    end

    # A boolean, or `default` if not given.
    def self.bool(parent : Mapping?, key : String, path : String, default : Bool) : Bool
      node = value(parent, key)
      return default unless node
      flag = node.as_bool?
      raise invalid(path, "must be true or false, got #{describe(node)}") if flag.nil?
      flag
    end

    # A string, or nil if not given.
    def self.string(parent : Mapping?, key : String, path : String) : String?
      node = value(parent, key)
      return unless node
      node.as_s? || raise invalid(path, "must be a string, got #{describe(node)}")
    end

    private def self.positive_int32!(path : String, n : Int64) : Int32
      raise invalid(path, "must be positive, got #{n}") unless n > 0
      raise invalid(path, "is too large: #{n}") if n > Int32::MAX
      n.to_i32
    end

    def self.invalid(path : String, problem : String) : InvalidPolicyError
      InvalidPolicyError.new("#{path} #{problem}")
    end

    # The node as the author wrote it, for messages.
    def self.describe(node : YAML::Any) : String
      case raw = node.raw
      when Hash  then "a mapping"
      when Array then "a list"
      else            raw.inspect
      end
    end
  end
end
