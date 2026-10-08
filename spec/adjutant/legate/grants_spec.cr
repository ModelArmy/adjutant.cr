require "../../spec_helper"

module Adjutant
  describe SizeLiteral do
    it "parses a bare byte count" do
      SizeLiteral.bytes("1024").should eq 1024_i64
    end

    it "parses KiB/MiB/GiB as binary (1024-based) units" do
      SizeLiteral.bytes("8MiB").should eq 8_388_608_i64
      SizeLiteral.bytes("1KiB").should eq 1024_i64
      SizeLiteral.bytes("4GiB").should eq 4_294_967_296_i64
    end

    it "tolerates a space between the number and unit" do
      SizeLiteral.bytes("512 MiB").should eq 536_870_912_i64
    end

    it "raises on garbage" do
      expect_raises(ArgumentError, /invalid size literal/) do
        SizeLiteral.bytes("lots")
      end
    end

    it "raises on an unrecognised unit" do
      expect_raises(ArgumentError, /invalid size literal/) do
        SizeLiteral.bytes("8TiB")
      end
    end
  end

  describe DurationLiteral do
    it "parses seconds" do
      DurationLiteral.seconds("300s").should eq 300
    end

    it "raises on garbage" do
      expect_raises(ArgumentError, /invalid duration literal/) do
        DurationLiteral.seconds("5m")
      end
    end

    it "raises on a bare number with no unit" do
      expect_raises(ArgumentError, /invalid duration literal/) do
        DurationLiteral.seconds("300")
      end
    end
  end

  describe Legate::Grants do
    describe ".deny_all" do
      it "grants nothing" do
        grants = Legate::Grants.deny_all
        grants.read_roots.should be_empty
        grants.write_roots.should be_empty
        grants.delete_roots.should be_empty
        grants.net_rules.should be_empty
        grants.net_methods.should be_empty
        grants.ambient_env.should be_empty
      end

      it "still fills in the spec-defaulted per-call limits" do
        limits = Legate::Grants.deny_all.limits
        limits.read_limit.should eq Legate::Limits::DEFAULT_READ_LIMIT
        limits.fetch_limit.should eq Legate::Limits::DEFAULT_FETCH_LIMIT
        limits.url_limit.should eq Legate::Limits::DEFAULT_URL_LIMIT
      end

      it "gives every per-run budget its default" do
        limits = Legate::Grants.deny_all.limits
        limits.memory.should eq 536_870_912_i64
        limits.wall_clock.should eq 300
        limits.total_read.should eq 4_294_967_296_i64
        limits.total_write.should eq 1_073_741_824_i64
      end
    end

    describe ".from_yaml" do
      # The full example from LEGATE.md §7 itself, so this spec breaks
      # loudly if the doc and the parser ever drift apart.
      full_example = <<-YAML
        grants:
          read:
            roots: ["/work/input", "/work/logs"]
          write:
            roots: ["/work/output"]
          delete:
            roots: ["/work/output/tmp"]
          net:
            hosts: ["api.example.com"]
            methods: [get, post]
          ambient:
            env: ["TZ", "LANG"]
        limits:
          read_limit: 8MiB
          fetch_limit: 32MiB
          memory: 512MiB
          wall_clock: 300s
          total_read: 4GiB
          total_write: 1GiB
        YAML

      it "parses every roots/hosts/binaries/env category from §7's own example" do
        grants = Legate::Grants.from_yaml(full_example)
        grants.read_roots.should eq ["/work/input", "/work/logs"]
        grants.write_roots.should eq ["/work/output"]
        grants.delete_roots.should eq ["/work/output/tmp"]
        grants.net_rules.size.should eq 1
        grants.net_rules.first.host.should eq "api.example.com"
        # §7's plain-string form still means what it always meant —
        # but its scheme and port are now PINNED to the fail-closed
        # defaults rather than being unconstrained. That change of
        # meaning is the whole point of net_rule.cr; see its own
        # top comment.
        grants.net_rules.first.scheme.should eq "https"
        grants.net_rules.first.ports.should eq [443]
        grants.net_rules.first.subdomains?.should be_false
        grants.net_methods.should eq ["get", "post"]
        grants.ambient_env.should eq ["TZ", "LANG"]
      end

      it "parses every limit from §7's own example" do
        limits = Legate::Grants.from_yaml(full_example).limits
        limits.read_limit.should eq 8_388_608_i64
        limits.fetch_limit.should eq 33_554_432_i64
        limits.memory.should eq 536_870_912_i64
        limits.wall_clock.should eq 300
        limits.total_read.should eq 4_294_967_296_i64
        limits.total_write.should eq 1_073_741_824_i64
        # §7's own example names no `url_limit`, so it falls back to
        # the 2 KiB default rather than being unbounded.
        limits.url_limit.should eq Legate::Limits::DEFAULT_URL_LIMIT
      end

      it "parses an explicit url_limit" do
        limits = Legate::Grants.from_yaml(<<-YAML).limits
        limits:
          url_limit: 4KiB
        YAML
        limits.url_limit.should eq 4_096_i64
      end

      it "denies everything and applies the default budgets when both top-level keys are absent" do
        grants = Legate::Grants.from_yaml("{}")
        grants.read_roots.should be_empty
        grants.limits.wall_clock.should eq Legate::Limits::DEFAULT_WALL_CLOCK
        grants.limits.total_write.should eq Legate::Limits::DEFAULT_TOTAL_WRITE
      end

      it "denies everything for a blank document, rather than raising YAML's own error" do
        ["", "   ", "\n", "# only a comment\n"].each do |source|
          grants = Legate::Grants.from_yaml(source)
          grants.read_roots.should be_empty
          grants.ambient_env.should be_empty
        end
      end

      it "rejects a document that is neither empty nor a mapping" do
        expect_raises(ArgumentError, /the document must be a mapping/) do
          Legate::Grants.from_yaml("just a string")
        end
      end

      it "treats a key with no value as not given" do
        grants = Legate::Grants.from_yaml(<<-YAML)
          grants:
            read:
          limits:
          YAML
        grants.read_roots.should be_empty
        grants.limits.read_limit.should eq Legate::Limits::DEFAULT_READ_LIMIT
      end

      it "reads budgets written as YAML integers, as bytes and seconds" do
        limits = Legate::Grants.from_yaml(<<-YAML).limits
          limits:
            total_read: 1048576
            wall_clock: 300
            max_open_streams: 8
          YAML
        limits.total_read.should eq 1_048_576_i64
        limits.wall_clock.should eq 300
        limits.max_open_streams.should eq 8
      end

      it "treats a present-but-empty category the same as an absent one" do
        grants = Legate::Grants.from_yaml(<<-YAML)
          grants:
            read:
              roots: []
          YAML
        grants.read_roots.should be_empty
      end

      it "denies a category missing from an otherwise-populated grants block" do
        grants = Legate::Grants.from_yaml(<<-YAML)
          grants:
            read:
              roots: ["/work/input"]
          YAML
        grants.read_roots.should eq ["/work/input"]
        grants.write_roots.should be_empty
      end

      it "downcases net methods" do
        grants = Legate::Grants.from_yaml(<<-YAML)
          grants:
            net:
              hosts: ["api.example.com"]
              methods: [GET, Post]
          YAML
        grants.net_methods.should eq ["get", "post"]
      end

      it "reads net.redirect_headers, downcased, and defaults it to none" do
        grants = Legate::Grants.from_yaml(<<-YAML)
          grants:
            net:
              hosts: ["api.example.com"]
              redirect_headers: [Accept, X-Trace]
          YAML
        grants.net_redirect_headers.should eq ["accept", "x-trace"]
        Legate::Grants.deny_all.net_redirect_headers.should be_empty
      end

      # A mistake must fail when the policy is loaded: read leniently,
      # each of these granted more, or enforced less, than written.
      describe "strictness" do
        it "rejects a misspelt key at any level, naming where" do
          expect_raises(ArgumentError, /limits has an unknown key "total_raed"/) do
            Legate::Grants.from_yaml("limits:\n  total_raed: 4GiB\n")
          end
          expect_raises(ArgumentError, /the document has an unknown key "limts"/) do
            Legate::Grants.from_yaml("limts:\n  total_read: 4GiB\n")
          end
          expect_raises(ArgumentError, /grants.read has an unknown key "root"/) do
            Legate::Grants.from_yaml("grants:\n  read:\n    root: [/work]\n")
          end
        end

        it "rejects a net.hosts mapping whose methods are misspelt or a scalar" do
          expect_raises(ArgumentError, /unknown key "method"/) do
            Legate::Grants.from_yaml(<<-YAML)
              grants:
                net:
                  methods: [get, post]
                  hosts:
                    - host: api.example.com
                      method: [get]
              YAML
          end
          expect_raises(ArgumentError, /methods must be a list/) do
            Legate::Grants.from_yaml(<<-YAML)
              grants:
                net:
                  methods: [get, post]
                  hosts:
                    - host: api.example.com
                      methods: GET
              YAML
          end
        end

        it "rejects an empty methods or ports list in a net.hosts mapping" do
          expect_raises(ArgumentError, /methods is empty/) do
            Legate::Grants.from_yaml("grants:\n  net:\n    hosts:\n      - host: a.example.com\n        methods: []\n")
          end
          expect_raises(ArgumentError, /ports is empty/) do
            Legate::Grants.from_yaml("grants:\n  net:\n    hosts:\n      - host: a.example.com\n        ports: []\n")
          end
        end

        it "rejects values of the wrong type" do
          {
            "grants:\n  read: [/work]\n"                                                        => /grants.read must be a mapping/,
            "grants:\n  net:\n    hosts:\n      - host: a.example.com\n        ports: 8443\n"   => /ports must be a list/,
            "grants:\n  net:\n    hosts:\n      - host: a.example.com\n        local: maybe\n"  => /local must be true or false/,
            "grants:\n  net:\n    hosts:\n      - host: a.example.com\n        subdomains: 1\n" => /subdomains must be true or false/,
            "grants:\n  ambient:\n    env: TZ\n"                                                => /grants.ambient.env must be a list/,
            "grants:\n  ambient:\n    env: [1]\n"                                               => /grants.ambient.env must list strings/,
            "limits:\n  max_open_streams: many\n"                                               => /max_open_streams must be a whole number/,
          }.each do |source, message|
            expect_raises(ArgumentError, message) { Legate::Grants.from_yaml(source) }
          end
        end

        it "rejects zero and negative limits" do
          {"limits:\n  total_read: 0\n", "limits:\n  wall_clock: -5\n", "limits:\n  max_open_streams: 0\n"}.each do |source|
            expect_raises(ArgumentError, /must be positive/) { Legate::Grants.from_yaml(source) }
          end
        end
      end

      it "fills in spec-defaulted per-call limits when limits: is absent entirely" do
        grants = Legate::Grants.from_yaml(<<-YAML)
          grants:
            read:
              roots: ["/work/input"]
          YAML
        grants.limits.read_limit.should eq Legate::Limits::DEFAULT_READ_LIMIT
        grants.limits.fetch_limit.should eq Legate::Limits::DEFAULT_FETCH_LIMIT
        grants.limits.url_limit.should eq Legate::Limits::DEFAULT_URL_LIMIT
      end
    end
  end
end
