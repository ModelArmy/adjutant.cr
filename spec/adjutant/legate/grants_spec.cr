require "../../spec_helper"

module Adjutant
  describe Legate::SizeLiteral do
    it "parses a bare byte count" do
      Legate::SizeLiteral.bytes("1024").should eq 1024_i64
    end

    it "parses KiB/MiB/GiB as binary (1024-based) units" do
      Legate::SizeLiteral.bytes("8MiB").should eq 8_388_608_i64
      Legate::SizeLiteral.bytes("1KiB").should eq 1024_i64
      Legate::SizeLiteral.bytes("4GiB").should eq 4_294_967_296_i64
    end

    it "tolerates a space between the number and unit" do
      Legate::SizeLiteral.bytes("512 MiB").should eq 536_870_912_i64
    end

    it "raises on garbage" do
      expect_raises(ArgumentError, /invalid size literal/) do
        Legate::SizeLiteral.bytes("lots")
      end
    end

    it "raises on an unrecognised unit" do
      expect_raises(ArgumentError, /invalid size literal/) do
        Legate::SizeLiteral.bytes("8TiB")
      end
    end
  end

  describe Legate::DurationLiteral do
    it "parses seconds" do
      Legate::DurationLiteral.seconds("300s").should eq 300
    end

    it "raises on garbage" do
      expect_raises(ArgumentError, /invalid duration literal/) do
        Legate::DurationLiteral.seconds("5m")
      end
    end

    it "raises on a bare number with no unit" do
      expect_raises(ArgumentError, /invalid duration literal/) do
        Legate::DurationLiteral.seconds("300")
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
        grants.net_hosts.should be_empty
        grants.net_methods.should be_empty
        grants.exec_binaries.should be_empty
        grants.ambient_env.should be_empty
      end

      it "defaults ambient_now to :live" do
        Legate::Grants.deny_all.ambient_now.should eq :live
      end

      it "still fills in the spec-defaulted per-call limits" do
        limits = Legate::Grants.deny_all.limits
        limits.read_limit.should eq Legate::Limits::DEFAULT_READ_LIMIT
        limits.fetch_limit.should eq Legate::Limits::DEFAULT_FETCH_LIMIT
      end

      it "leaves per-run budgets unenforced (nil)" do
        limits = Legate::Grants.deny_all.limits
        limits.memory.should be_nil
        limits.wall_clock.should be_nil
        limits.total_read.should be_nil
        limits.total_write.should be_nil
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
          exec:
            binaries: ["/usr/bin/git", "/usr/bin/rg"]
          ambient:
            env: ["TZ", "LANG"]
            now: pinned
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
        grants.net_hosts.should eq ["api.example.com"]
        grants.net_methods.should eq ["get", "post"]
        grants.exec_binaries.should eq ["/usr/bin/git", "/usr/bin/rg"]
        grants.ambient_env.should eq ["TZ", "LANG"]
        grants.ambient_now.should eq :pinned
      end

      it "parses every limit from §7's own example" do
        limits = Legate::Grants.from_yaml(full_example).limits
        limits.read_limit.should eq 8_388_608_i64
        limits.fetch_limit.should eq 33_554_432_i64
        limits.memory.should eq 536_870_912_i64
        limits.wall_clock.should eq 300
        limits.total_read.should eq 4_294_967_296_i64
        limits.total_write.should eq 1_073_741_824_i64
      end

      it "denies everything and leaves budgets unenforced when both top-level keys are absent" do
        grants = Legate::Grants.from_yaml("{}")
        grants.read_roots.should be_empty
        grants.limits.memory.should be_nil
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
        grants.exec_binaries.should be_empty
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

      it "defaults ambient_now to :live when omitted" do
        grants = Legate::Grants.from_yaml(<<-YAML)
          grants:
            ambient:
              env: ["TZ"]
          YAML
        grants.ambient_now.should eq :live
      end

      it "fills in spec-defaulted per-call limits when limits: is absent entirely" do
        grants = Legate::Grants.from_yaml(<<-YAML)
          grants:
            read:
              roots: ["/work/input"]
          YAML
        grants.limits.read_limit.should eq Legate::Limits::DEFAULT_READ_LIMIT
        grants.limits.fetch_limit.should eq Legate::Limits::DEFAULT_FETCH_LIMIT
      end
    end
  end
end
