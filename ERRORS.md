# Error codes

Every error Adjutant reports carries a short code such as `R008` or `P003`.
This file says what each one means and what to do about it.

Codes are stable. Once allocated, a code is never reused for a different
problem and never renumbered, so it is safe to look up, match on in a test,
or store in a log.

## Reading a code

The letter says what *kind* of problem it is — and therefore what to do
next, which differs sharply between them:

|Letter|Meaning                                           |What to do                                     |
|------|--------------------------------------------------|-----------------------------------------------|
|`P`   |The script could not be parsed                    |Fix the syntax                                 |
|`C`   |Parsed, but rejected before running               |Fix the code that was rejected                 |
|`R`   |Something went wrong while running                |Fix the script                                 |
|`L`   |A limit was reached                               |Simplify the script, or raise the limit        |
|`U`   |A construct Adjutant deliberately does not support|Use the documented alternative                 |
|`F`   |A risk policy declined the call                   |Adjust the policy, or don't make the call      |
|`N`   |A function the host provided raised               |Check the arguments, then report it to the host|
|`H`   |The program embedding Adjutant called it wrongly  |Fix the integration                            |
|`I`   |Adjutant itself has a bug                         |Nothing — please report it                     |

The letter describes the problem, not the part of Adjutant that noticed it.

## What an error looks like

```
error[U001]: block parameter capture (`&blk`) is not supported
script.rb:1:9
1 | def foo(&blk)
  |         ^^^^
  |         not usable as a value
why:  A block passed to a method can only be run synchronously, via
      `yield`, inside the call it was passed to. It never becomes a value,
      so it cannot be bound to the parameter `blk`, stored, returned, or
      called later.
help: Run the block with `yield` inside `foo`, or take a lambda as an
      ordinary parameter and call it with `.call`.
```

Not every error has all of these. Some carry no source location, because
the failure happened before any script was involved. Some carry no `help`,
because there is nothing for the reader to change.

## Placeholders

Error text is filled in from the failure itself — a name, a type, a limit.
Each code's placeholders are listed with it below.

If a placeholder appears in the output literally, braces and all, the error
was constructed without that value. That is a bug in Adjutant; please
report it.

---

## P — Syntax

The script could not be parsed. Nothing ran.

|Code|Meaning                                        |Placeholders                    |
|----|-----------------------------------------------|--------------------------------|
|P001|Expected one thing, found another              |`expected`, `found`             |
|P002|This can't start an expression                 |`found`                         |
|P003|A block construct is missing its `end`         |`construct`, `found`, `expected`|
|P004|`else` without `rescue` is useless             |—                               |
|P005|A `begin` block can have only one `else` clause|—                               |

P003 points at two places: where the parser ran out of input, and the
`def`, `class`, `if`, or other construct that was never closed. The second
is usually the one to fix. Note that an `end` arriving *too early* also
produces this — it closes the innermost block, leaving an outer one open.

P004 and P005 match real Ruby's own `SyntaxError`s exactly (confirmed
against `irb`) — `else` in a `begin` block is only meaningful paired with
at least one `rescue` clause, and a `begin` allows at most one `else`,
the same as it allows at most one `ensure`.

## C — Static semantics

The script parsed, but was rejected before running.

|Code|Meaning                                |Placeholders|
|----|---------------------------------------|------------|
|C001|Left-hand side of `=` can't be assigned|`target`    |
|C002|`redo` used outside any loop           |—           |

## R — Runtime

Something went wrong while the script was running.

|Code|Meaning                                               |Placeholders            |
|----|------------------------------------------------------|------------------------|
|R001|Constant assigned a second time                       |`name`                  |
|R002|Class variable used outside a class or module body    |—                       |
|R003|Uninitialized constant                                |`name`                  |
|R004|`::` used on something that isn't a class or module   |`value`                 |
|R005|Unary operator not applicable to this type            |`operator`, `type`      |
|R006|Method definition with no class or module to attach to|`definition`            |
|R007|`yield` reached, but no block was passed              |`method`                |
|R008|Undefined method or variable                          |`name`                  |
|R009|Modules cannot be instantiated                        |`module`                |
|R010|`require` cannot find the named module                |`path`                  |
|R011|Missing a required keyword argument                   |`name`, `method`        |
|R012|Passed a keyword argument the method doesn't declare  |`name`, `method`        |
|R013|`<=>` returned a non-integer for `<`/`<=`/`>`/`>=`    |`left`, `right`, `value`|
|R014|`super` called, but no ancestor defines the method    |`method`                |
|R015|`Integer#to_s` given an out-of-range base             |`base`                  |
|R016|`Float#to_i` called on Infinity or NaN                |`value`                 |
|R017|`Hash#merge` given a non-Hash argument                |`class_name`            |

Scripts can `rescue` these. R008 raises a `NameError`, matching Ruby;
R011, R012, and R015 raise `ArgumentError`, also matching Ruby; R014
raises a `NoMethodError`, also matching Ruby; R016 raises a
`FloatDomainError`, also matching Ruby; R017 raises a `TypeError`,
also matching Ruby; the rest raise `RuntimeError`.

Adjutant's constants are assign-once, which Ruby only warns about. R001 is
that rule firing on an ordinary constant; reopening a class or module is
U003 instead.

R011/R012 apply to script-defined methods only. A native function, a
builtin, or `Class.new`/`initialize` has no declared `name:` parameter
list to check against — passing any keyword argument to one of these
raises R012 outright, rather than silently discarding it.

## L — Limits

The script is valid — it just exceeded something Adjutant is willing to do.

|Code|Meaning                                       |Can the host raise it?|Placeholders|
|----|----------------------------------------------|----------------------|------------|
|L001|Loops nested too deeply                       |no                    |`limit`     |
|L002|Too many method or block calls active at once |`call_depth_limit`    |`limit`     |
|L003|Too many intermediate values in one expression|no                    |`limit`     |
|L004|The script ran too long without finishing     |`instruction_limit`   |`limit`     |

Runaway recursion usually shows up as L002, and a loop that never
terminates as L004. Where the right-hand column names a setting, the
program embedding Adjutant can raise that ceiling; where it says no, the
limit is fixed and the script needs restructuring.

## U — Deliberately unsupported

Adjutant is a subset of Ruby. These constructs are not missing features
awaiting implementation — they will not be added, and each has a documented
alternative in [UNSUPPORTED.md](./UNSUPPORTED.md).

|Code|Construct                                       |Placeholders     |
|----|------------------------------------------------|-----------------|
|U001|`&blk` parameter capture                        |`param`, `method`|
|U002|`Class.new` / `Module.new`                      |`class`          |
|U003|Reopening a class or module                     |`name`           |
|U004|Defining a method inside another method         |`definition`     |
|U005|Calling a method by computed name               |`construct`      |
|U006|`eval` / `instance_eval`                        |—                |
|U007|Reflection into the host's internals            |—                |
|U008|`private`/`protected`/`public`                  |`construct`      |
|U009|`Struct.new`                                    |—                |
|U010|_retired — see UNSUPPORTED.md, not an exclusion_|—                |
|U011|`$globals`                                      |`name`           |
|U012|Numbered block parameters (`_1`, `_2`)          |—                |
|U013|Endless method definitions                      |—                |
|U014|`class << self` singleton-class syntax          |—                |
|U015|`undef` / method-added hooks                    |`construct`      |
|U016|`begin...end while`/`until` (do-while)          |—                |
|U017|Operator-method overloading (`def ==`, ...)     |`operator`       |
|U018|`extend`/`include` via an explicit receiver     |`construct`      |

U005 and U006 are reported when a name that would resolve to one of them
resolves to nothing else. A script is still free to define its own method
with one of those names — `def send` on your own class works, and calling
it works.

U010 was investigated and found not to be a real gap — see
[UNSUPPORTED.md](./UNSUPPORTED.md) for what changed. The code is
retired, not reassigned: codes are never reused for a different
problem once allocated (see "Reading a code" above).

**U008, U009, U011–U015 status: decided, not yet enforced.** Using one
of these constructs today falls through to an ordinary undefined-name
or generic parse error rather than naming the construct specifically —
expect a less-specific error than the table above until enforcement
lands. See [UNSUPPORTED.md](./UNSUPPORTED.md) for the reasoning behind
each and what to write instead.

**U016 status: actively enforced.** Both the do-while statement
(`begin...end while cond`) and its assigned-expression form
(`x = begin...end while cond`) are rejected. See
[UNSUPPORTED.md](./UNSUPPORTED.md) for the reasoning.

**U017 status: actively enforced.** `def ==`, `def <`, `def +`,
`def ===`, and every other operator method except `<=>` are rejected
before the method is ever defined. See
[UNSUPPORTED.md](./UNSUPPORTED.md) for the reasoning.

## F — Risk flow

Not a failure. The script asked to do something the host's risk policy
declines to permit.

|Code|Meaning                                     |Placeholders    |
|----|--------------------------------------------|----------------|
|F001|A call matched a policy rule that rejects it|`call`, `reason`|

A script can handle a refusal rather than aborting, by rescuing
`RiskFlowRejectedError`. If the call is legitimate, the policy needs a rule
that allows it.

## N — Native layer

A function the host registered raised while the script was calling it. The
message shown is that function's own.

|Code|Meaning                               |Placeholders         |
|----|--------------------------------------|---------------------|
|N001|A function provided by the host raised|`function`, `message`|

Adjutant cannot tell whether the script passed bad arguments or the host's
function is broken, which is why this is its own category rather than an
ordinary runtime fault. Check the arguments first; if they are right, the
failure belongs to whoever provides the function.

## H — Host API misuse

The program embedding Adjutant called it incorrectly. Neither the script
nor Adjutant is at fault, and no script is necessarily involved — some of
these fire while the host is still setting Adjutant up.

|Code|Meaning                                        |Placeholders                 |
|----|-----------------------------------------------|-----------------------------|
|H001|A `RiskProfile` with no tags claiming risk     |—                            |
|H002|`reversible: Depends` with no explanatory note |—                            |
|H003|Two policy rules tie at the same priority      |`count`, `priority`, `target`|
|H004|`invoke_proc` given something that isn't a Proc|`found`                      |
|H005|A VM was reused for a second script            |—                            |
|H006|`require` used on a VM with no interpreter     |—                            |

These carry no source location, since there is no script position that
would be honest to point at.

To catch them: H001, H002, and H004 are `Adjutant::HostArgumentError`,
which is an `ArgumentError`. H005 and H006 are
`Adjutant::HostStateError`. H003 is
`Adjutant::AmbiguousRiskFlowPolicyError`. They are separate classes
because they are separate problems — bad arguments, wrong sequencing, and
an ambiguous policy respectively.

H004 arrives wrapped in an N001, because the only way to reach it is from
inside a native function.

## I — Internal

Adjutant has a bug. There is nothing to fix in the script or in the
integration.

|Code|Meaning                                          |Placeholders|
|----|-------------------------------------------------|------------|
|I001|The VM read an instruction it does not implement |`opcode`    |
|I002|A jump was left unresolved                       |`target`    |
|I003|The value stack went below its frame             |—           |
|I004|A builtin class was used before it was registered|`class`     |
|I005|The compiler has no case for part of the syntax  |`node`      |
|I006|The compiler has no instruction for an operator  |`operator`  |
|I007|Risk aggregation met a node kind it can't handle |`node`      |

Most arrive as a `CompileError` or `RuntimeError`, depending on when they
happen. I007 is an `Adjutant::InternalError`, because risk aggregation is
neither compiling nor running.

These carry no suggestions, because none would be honest. Instead they end
with an address to report to. Copying the whole report is genuinely useful:
the detail in it is what makes the bug findable.

The address is set by whoever ships Adjutant, so it may point at them
rather than at this project — they can triage and forward.
