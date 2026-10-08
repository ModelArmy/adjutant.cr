require "../spec_helper"

module Adjutant
  class PolicySpecVaultShare < PolicyShare
  end

  # A provider claiming `grants.vault`, or another key when given one.
  class PolicySpecVaultSection < PolicySection
    def initialize(@grant_key = "vault")
    end

    def name : String
      "vault"
    end

    def grant_keys : Array(String)
      [@grant_key]
    end

    def limit_keys : Array(String)
      [] of String
    end

    def load(grants : YamlPolicy::Mapping?, limits : YamlPolicy::Mapping?) : PolicyShare
      PolicySpecVaultShare.new
    end
  end

  describe Policy do
    describe ".from_yaml" do
      it "loads all three sections" do
        policy = Policy.from_yaml(<<-YAML)
          grants:
            read:
              roots: [/work/input]
            net:
              hosts: [api.example.com]
          limits:
            read_limit: 1MiB
            wall_clock: 60s
          risk_flow:
            patterns:
              - { kind: env, type: regex, pattern: "_KEY$", priority: 0, sensitivity: high }
            rules:
              - { authority: net, sensitivity: high, action: reject }
            default: ask
          YAML
        policy.grants.read_roots.should eq ["/work/input"]
        policy.grants.net_rules.size.should eq 1
        policy.grants.limits.read_limit.should eq 1_048_576_i64
        policy.grants.limits.wall_clock.should eq 60
        pattern = policy.risk_flow.sensitivity_patterns.first
        pattern.kind.should eq ProvenanceKind::Env
        pattern.pattern_type.should eq PatternType::Regex
        pattern.sensitivity.should eq Sensitivity::High
        policy.risk_flow.risk_flow_rules.first.action.should eq RiskFlowAction::Reject
        policy.risk_flow.default_action.should eq RiskFlowAction::Ask
      end

      it "loads an exception's origin and subject" do
        policy = Policy.from_yaml(<<-YAML)
          risk_flow:
            rules:
              - authority: net
                sensitivity: high
                action: allow
                priority: 10
                origin: { kind: env, pattern: STRIPE_KEY }
                subject: { pattern: "https://api.stripe.com:443" }
            default: reject
          YAML
        rule = policy.risk_flow.risk_flow_rules.first
        rule.priority.should eq 10
        rule.origin.try(&.pattern).should eq "STRIPE_KEY"
        rule.subject.try(&.pattern).should eq "https://api.stripe.com:443"
      end

      it "takes `risk_flow: none` as judging no flows" do
        Policy.from_yaml("risk_flow: none\n").risk_flow.reject_all_flows?.should be_true
      end

      it "grants nothing, with default limits, when grants and limits are absent" do
        grants = Policy.from_yaml("risk_flow: none\n").grants
        grants.read_roots.should be_empty
        grants.net_rules.should be_empty
        grants.ambient_env.should be_empty
        grants.limits.read_limit.should eq Legate::Limits::DEFAULT_READ_LIMIT
        grants.limits.total_read.should eq ResourceLimits::DEFAULT_TOTAL_READ
      end

      describe "refuses" do
        it "a document without risk_flow" do
          expect_raises(InvalidPolicyError, /needs a `risk_flow:` section/) do
            Policy.from_yaml("grants:\n  read:\n    roots: [/work]\n")
          end
        end

        it "an empty document, which has no risk_flow" do
          expect_raises(InvalidPolicyError, /needs a `risk_flow:` section/) do
            Policy.from_yaml("")
          end
        end

        it "a risk_flow with neither patterns nor rules, which would judge nothing" do
          expect_raises(InvalidPolicyError, /risk_flow has neither patterns nor rules/) do
            Policy.from_yaml("risk_flow:\n  default: reject\n")
          end
        end

        it "a risk_flow that is neither none nor a mapping" do
          expect_raises(InvalidPolicyError, /risk_flow must be `none` or a mapping/) do
            Policy.from_yaml("risk_flow: nothing\n")
          end
        end

        it "a document that isn't YAML" do
          expect_raises(InvalidPolicyError, /not valid YAML/) do
            Policy.from_yaml("risk_flow: [none\n")
          end
        end

        it "unknown keys, naming where" do
          {
            "risk_flow: none\ngrant: {}\n"                                                                                                                                                  => /the document has an unknown key "grant"/,
            "risk_flow: none\ngrants:\n  vault: {}\n"                                                                                                                                       => /grants has an unknown key "vault"/,
            "risk_flow: none\nlimits:\n  read_limt: 1MiB\n"                                                                                                                                 => /limits has an unknown key "read_limt"/,
            "risk_flow:\n  rule: []\n"                                                                                                                                                      => /risk_flow has an unknown key "rule"/,
            "risk_flow:\n  patterns:\n    - { kind: env, pattern: K, priority: 0, sensitivity: high, typ: regex }\n  default: reject\n"                                                     => /risk_flow.patterns\[0\] has an unknown key "typ"/,
            "risk_flow:\n  rules:\n    - { authority: net, sensitivity: high, action: allow, priority: 1, origin: { kind: env, pattern: K }, subjct: { pattern: x } }\n  default: reject\n" => /risk_flow.rules\[0\] has an unknown key "subjct"/,
            "risk_flow:\n  rules:\n    - { authority: net, sensitivity: high, action: allow, priority: 1, origin: { kind: env, pattern: K, host: x } }\n  default: reject\n"                => /risk_flow.rules\[0\].origin has an unknown key "host"/,
            "risk_flow:\n  rules:\n    - { authority: net, sensitivity: high, action: allow, priority: 1, subject: { pattern: x, host: y } }\n  default: reject\n"                         => /risk_flow.rules\[0\].subject has an unknown key "host"/,
          }.each do |source, message|
            expect_raises(InvalidPolicyError, message) { Policy.from_yaml(source) }
          end
        end

        it "wrong values, naming where" do
          {
            "risk_flow: none\nlimits:\n  read_limit: lots\n"                                                                   => /limits.read_limit must be a size/,
            "risk_flow:\n  rules:\n    - { authority: net, sensitivity: high, action: maybe }\n"                               => /risk_flow.rules\[0\].action must be one of allow, ask, reject/,
            "risk_flow:\n  rules:\n    - { authority: net, sensitivity: High, action: reject }\n"                              => /risk_flow.rules\[0\].sensitivity must be one of/,
            "risk_flow:\n  patterns:\n    - { kind: env, pattern: K, priority: high, sensitivity: high }\n  default: reject\n" => /risk_flow.patterns\[0\].priority must be a whole number/,
            "risk_flow:\n  patterns: {}\n  default: reject\n"                                                                  => /risk_flow.patterns must be a list/,
          }.each do |source, message|
            expect_raises(InvalidPolicyError, message) { Policy.from_yaml(source) }
          end
        end

        it "a missing required key, naming it" do
          expect_raises(InvalidPolicyError, /risk_flow.patterns\[0\] needs a `priority:` key/) do
            Policy.from_yaml("risk_flow:\n  patterns:\n    - { kind: env, pattern: K, sensitivity: high }\n  default: reject\n")
          end
        end

        it "what a risk-flow policy refuses when built" do
          expect_raises(InvalidPolicyError, /\Arisk_flow: /) do
            Policy.from_yaml("risk_flow:\n  rules:\n    - { authority: net, sensitivity: high, action: reject }\n")
          end
          expect_raises(InvalidPolicyError, /\Arisk_flow: /) do
            Policy.from_yaml("risk_flow:\n  rules:\n    - { authority: net, sensitivity: high, action: reject }\n  default: allow\n")
          end
        end

        it "a network rule Legate refuses" do
          expect_raises(InvalidPolicyError, /scheme must be http or https/) do
            Policy.from_yaml("risk_flow: none\ngrants:\n  net:\n    hosts:\n      - { host: a.example.com, scheme: ftp }\n")
          end
        end
      end

      describe "ownership" do
        it "accepts a key a registered section claims" do
          sections = Policy.default_sections << PolicySpecVaultSection.new
          policy = Policy.from_yaml("risk_flow: none\ngrants:\n  vault:\n    anything: 1\n", sections)
          policy.grants.read_roots.should be_empty
        end

        it "refuses two sections claiming one key, before reading the document" do
          sections = Policy.default_sections << PolicySpecVaultSection.new("net")
          error = expect_raises(ArgumentError, /grants.net is claimed by both legate and vault/) do
            Policy.from_yaml("not: [valid", sections)
          end
          error.should_not be_a(InvalidPolicyError)
        end
      end
    end
  end
end
