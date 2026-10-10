# Policy

**Status** Built. Specifies the policy document a host writes.
**Audience** Hosts embedding Adjutant, and anyone adding an effect provider.

A script runs under one policy, fixed before its first line runs. The host writes it as one YAML document and passes the text to `Adjutant::Policy.from_yaml`; Adjutant never reads a policy from disk. The document has three sections:

1. `grants`: what a run may touch at all. Everything not granted is denied.
2. `limits`: how much a run may consume, per call and per run.
3. `risk_flow`: where sensitive data may go once it has been read.

`grants` and `limits` are the perimeter; `risk_flow` judges what moves inside it. A call must pass both.

```crystal
policy = Adjutant::Policy.from_yaml(File.read("policy.yaml"))
interp = Adjutant::Interpreter.new(policy: policy, on_risk_flow_decision: decide, effect: effect)
```

## 1. Loading

The document is read strictly, so a mistake fails when it is loaded rather than granting more, or enforcing less, than written. Each of these raises `InvalidPolicyError` naming where, as a dotted path such as `risk_flow.rules[2].subject`:

1. A key no part of Adjutant claims, at any level.
2. A value of the wrong type, an empty list where a list must hold something, or a zero or negative limit.
3. A missing `risk_flow` section.
4. A `risk_flow` mapping with neither `patterns` nor `rules`.
5. Anything §4 refuses: an uncovered pair, `default: allow`, a regex that doesn't compile, or a certain tie.

A key with no value counts as absent. An empty document is refused, since it has no `risk_flow`.

Absent sections fail closed:

Section    |When absent                                
-----------|-------------------------------------------
`grants`   |Nothing granted                            
`limits`   |Every limit at its default (§3)            
`risk_flow`|Refused; write `risk_flow: none` to opt out

## 2. Grants

```yaml
grants:
  read:
    roots: ["/work/input"]
  write:
    roots: ["/work/output"]
  delete:
    roots: ["/work/output/tmp"]
  net:
    hosts: [api.example.com]
  ambient:
    env: ["TZ"]
```

`read`, `write` and `delete` grant filesystem roots, and are core's: a path is inside a root when its real path is, links followed. `net` and `ambient` are Legate's; LEGATE.md §7 gives their keys. A provider added later claims its own keys here.

## 3. Limits

```yaml
limits:
  wall_clock: 300s
  total_read: 4GiB
  read_limit: 8MiB
```

Sizes may be written as literals (`8MiB`) or byte counts, and `wall_clock` as `300s` or `300`. Every limit has a default, so a policy that names none still bounds a run.

Key               |Owner |Scope   |Breach     |Default
------------------|------|--------|-----------|-------
`wall_clock`      |Core  |Per run |Fatal      |300s   
`total_read`      |Core  |Per run |Fatal      |4GiB   
`total_write`     |Core  |Per run |Fatal      |1GiB   
`memory`          |Core  |Per run |Advice only|512MiB 
`max_open_streams`|Core  |At once |Recoverable|64     
`read_limit`      |Legate|Per call|Recoverable|8MiB   
`fetch_limit`     |Legate|Per call|Recoverable|32MiB  
`url_limit`       |Legate|Per call|Recoverable|2KiB   
`stream_limit`    |Legate|Per call|Recoverable|1GiB   

A per-run budget is fatal because a script allowed to catch it and retry would reinstate the exhaustion it exists to prevent. `max_open_streams` caps what is held at once, not what is consumed, so closing a stream frees a slot and the breach is recoverable.

A run is one `Interpreter#eval`, and the per-run budgets start afresh with each. `wall_clock` is checked before every effectful call and, every 1,024 instructions, by the VM itself, so a loop that makes no calls meets it too. Time the host spends deciding a risk-flow Ask doesn't count, since the script can do nothing while it waits. `memory` is advice to whatever enforces memory at the OS tier (cgroups, rlimit); Adjutant does not track it.

## 4. Risk flow

Every value read from outside the VM carries the origins it came from, each with a sensitivity. When the value reaches a call, each origin is judged against the call's authority and the worst answer decides.

### 4.1 Opting out

```yaml
risk_flow: none
```

No pattern makes an origin sensitive, so Legate's reads are never judged and only the perimeter applies. A host function that marks its own data sensitive is still refused when that data reaches a call. This is the only way to opt out: a mapping with no patterns and no rules would do the same while reading as if it judged something, and is refused.

### 4.2 Patterns

```yaml
risk_flow:
  patterns:
    - { kind: file, pattern: /work/input/.env, priority: 10, sensitivity: high }
    - { kind: env, type: regex, pattern: "_KEY$", priority: 0, sensitivity: high }
```

A pattern gives origins of one `kind` (`file`, `host`, `env`, `user_input`) a sensitivity (`none`, `elevated`, `high`). It matches by `type: exact` (the default) or `regex`. An origin no pattern matches is `none`. When several match, the highest `priority` decides.

A file origin is its real path, and a host origin is lowercase without a trailing dot. An exact pattern is put in the same form when the policy is loaded, so a script can't respell its way past one; a regex is matched against that form as written, so anchor a path regex on a real directory.

### 4.3 Rules

```yaml
  rules:
    - { authority: net, sensitivity: high, action: reject }
    - { authority: read, sensitivity: high, action: allow }
  default: ask
```

A rule gives one pair of authority (`read`, `write`, `delete`, `net`, `ambient`, `log`) and sensitivity (`elevated`, `high`) an action: `allow`, `ask` or `reject`. `none` is always allowed. Every pair needs an action, from a rule or from `default`, which may be `ask` or `reject` but never `allow`; a pair left uncovered is refused when loaded, so an authority added later can't open a gap. An `ask` calls the host's `on_risk_flow_decision`.

### 4.4 Exceptions

A rule naming where the data came from (`origin`), where it is going (`subject`), or both, is an exception. It overrides the pair's rule for the flows it matches, needs a `priority`, and never covers a pair on its own:

```yaml
    - authority: net
      sensitivity: high
      action: allow
      priority: 10
      origin: { kind: env, pattern: STRIPE_KEY }
      subject: { pattern: "https://api.stripe.com:443" }
```

A subject is named as Legate names it: a real path, or `scheme://host:port`. A value carrying the key and another secret is judged on each origin, so the second secret is still refused at `api.stripe.com`.

### 4.5 Ties

Two patterns, or two exceptions, deciding the same origin or flow at one priority leave no answer. Where the policy alone makes the tie certain (identical entries, or an exact entry another matches, with nothing higher deciding it), loading refuses it. Where only a real value reveals it, as between two regexes, the run that meets it ends with H003, past any `rescue`.

## 5. Ownership

Each key under `grants` and `limits` is parsed by the section that claims it, and a key no section claims is refused (§1). Core and each effect provider register a `PolicySection`; two claiming one key raise `ArgumentError` before any document is read, since that is a provider's bug, not the author's. `risk_flow` is core's alone: its authorities are a closed set, so what a policy means doesn't depend on which providers are loaded.

Key                               |Owner 
----------------------------------|------
`grants.read`, `.write`, `.delete`|Core  
`grants.net`, `grants.ambient`    |Legate
Per-run limits, `max_open_streams`|Core  
Per-call limits                   |Legate
`risk_flow`                       |Core  
