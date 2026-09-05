require "../../spec_helper"

# Pulls the first entry out of a `hosts:` list so each spec below can
# write the YAML in exactly the shape a real policy file uses, rather
# than hand-building a YAML::Any.
private def host_node(yaml : String) : YAML::Any
  YAML.parse(yaml)["hosts"].as_a.first
end

module Adjutant
  describe Legate::NetRule do
    describe ".parse — the scalar forms" do
      it "reads a bare hostname as https on 443" do
        rule = Legate::NetRule.parse("api.example.com")
        rule.host.should eq "api.example.com"
        rule.scheme.should eq "https"
        rule.ports.should eq [443]
        rule.subdomains?.should be_false
        rule.local?.should be_false
        rule.methods.should be_empty
      end

      it "reads a host:port pair" do
        rule = Legate::NetRule.parse("api.example.com:8443")
        rule.host.should eq "api.example.com"
        rule.scheme.should eq "https"
        rule.ports.should eq [8443]
      end

      it "reads a full URL, scheme and port together" do
        rule = Legate::NetRule.parse("http://internal.example.com:8080")
        rule.host.should eq "internal.example.com"
        rule.scheme.should eq "http"
        rule.ports.should eq [8080]
      end

      it "does not set local for a scalar entry" do
        Legate::NetRule.parse("localhost:11434").local?.should be_false
      end

      it "defaults a scheme-only http URL to port 80, not 443" do
        Legate::NetRule.parse("http://internal.example.com").ports.should eq [80]
      end

      it "normalizes case and a trailing dot" do
        Legate::NetRule.parse("API.Example.COM.").host.should eq "api.example.com"
      end

      it "rejects a scheme that is neither http nor https" do
        expect_raises(ArgumentError, /must be http or https/) do
          Legate::NetRule.parse("ftp://files.example.com")
        end
      end

      it "rejects a non-numeric port" do
        expect_raises(ArgumentError, /non-numeric port/) do
          Legate::NetRule.parse("api.example.com:https")
        end
      end

      it "rejects an out-of-range port" do
        expect_raises(ArgumentError, /out of range/) do
          Legate::NetRule.parse("api.example.com:70000")
        end
      end

      it "rejects an empty entry" do
        expect_raises(ArgumentError, /empty net.hosts entry/) do
          Legate::NetRule.parse("   ")
        end
      end

      # Deliberately loud rather than silently mis-split on the first
      # colon, which would build a rule for a host that doesn't exist
      # and then deny every real connection to it with a baffling
      # reason. Logged in SCOPE.md.
      it "rejects an IPv6 literal rather than mangling it" do
        expect_raises(ArgumentError, /IPv6 literals are not supported/) do
          Legate::NetRule.parse("[2001:db8::1]:8443")
        end
      end
    end

    describe ".from_yaml_node — the mapping form" do
      it "reads every field" do
        rule = Legate::NetRule.from_yaml_node(host_node(<<-YAML))
        hosts:
          - host: internal.example.com
            scheme: http
            ports: [8080, 8081]
            methods: [get]
            subdomains: true
            local: true
        YAML
        rule.host.should eq "internal.example.com"
        rule.scheme.should eq "http"
        rule.ports.should eq [8080, 8081]
        rule.methods.should eq ["get"]
        rule.subdomains?.should be_true
        rule.local?.should be_true
      end

      it "applies the fail-closed defaults for every omitted field" do
        rule = Legate::NetRule.from_yaml_node(host_node(<<-YAML))
        hosts:
          - host: api.example.com
        YAML
        rule.scheme.should eq "https"
        rule.ports.should eq [443]
        rule.subdomains?.should be_false
        rule.local?.should be_false
        rule.methods.should be_empty
      end

      it "still accepts the plain-string form §7's own example uses" do
        rule = Legate::NetRule.from_yaml_node(host_node(<<-YAML))
        hosts:
          - api.example.com
        YAML
        rule.host.should eq "api.example.com"
        rule.ports.should eq [443]
      end

      it "downcases methods, so [GET, Post] matches a lowercased check" do
        rule = Legate::NetRule.from_yaml_node(host_node(<<-YAML))
        hosts:
          - host: api.example.com
            methods: [GET, Post]
        YAML
        rule.methods.should eq ["get", "post"]
      end

      it "requires a host: key in a mapping entry" do
        expect_raises(ArgumentError, /needs a `host:` key/) do
          Legate::NetRule.from_yaml_node(host_node(<<-YAML))
          hosts:
            - scheme: https
          YAML
        end
      end

      it "rejects a non-integer port" do
        expect_raises(ArgumentError, /is not an integer/) do
          Legate::NetRule.from_yaml_node(host_node(<<-YAML))
          hosts:
            - host: api.example.com
              ports: ["http"]
          YAML
        end
      end
    end

    describe "parsing through Grants.from_yaml" do
      it "builds rules for a mixed list of scalar and mapping entries" do
        grants = Legate::Grants.from_yaml(<<-YAML)
        grants:
          net:
            methods: [get, post]
            hosts:
              - api.example.com
              - "https://files.example.com:8443"
              - host: internal.example.com
                scheme: http
                ports: [8080]
                methods: [get]
        YAML
        grants.net_rules.size.should eq 3
        grants.net_rules[0].ports.should eq [443]
        grants.net_rules[1].ports.should eq [8443]
        grants.net_rules[2].scheme.should eq "http"
        grants.net_methods.should eq ["get", "post"]
      end

      # A malformed POLICY is an embedder error surfaced loudly at
      # load time, not a silently-denied grant discovered at call
      # time — same posture SizeLiteral/DurationLiteral already take.
      it "raises at load time on a malformed entry rather than denying quietly" do
        expect_raises(ArgumentError) do
          Legate::Grants.from_yaml(<<-YAML)
          grants:
            net:
              hosts: ["ftp://files.example.com"]
          YAML
        end
      end
    end

    describe "#to_s — the denial-reason rendering" do
      it "spells the rule out in the shape the policy file used" do
        rule = Legate::NetRule.new(host: "b.com", ports: [8080, 8081], subdomains: true)
        rule.to_s.should eq "https://b.com:8080,8081 (+subdomains)"
      end

      it "shows the local opt-in" do
        rule = Legate::NetRule.new(host: "localhost", scheme: "http", ports: [11434], local: true)
        rule.to_s.should eq "http://localhost:11434 (+local)"
      end
    end
  end
end
