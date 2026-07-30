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

|Code|Meaning                               |Placeholders                    |
|----|--------------------------------------|--------------------------------|
|P001|Expected one thing, found another     |`expected`, `found`             |
|P002|This can't start an expression        |`found`                         |
|P003|A block construct is missing its `end`|`construct`, `found`, `expected`|

P003 points at two places: where the parser ran out of input, and the
`def`, `class`, `if`, or other construct that was never closed. The second
is usually the one to fix. Note that an `end` arriving *too early* also
produces this — it closes the innermost block, leaving an outer one open.

## C — Static semantics

The script parsed, but was rejected before running.

|Code|Meaning                                |Placeholders|
|----|---------------------------------------|------------|
|C001|Left-hand side of `=` can't be assigned|`target`    |
|C002|`redo` used outside any loop           |—           |

## R — Runtime

Something went wrong while the script was running.

|Code|Meaning                                               |Placeholders      |
|----|------------------------------------------------------|------------------|
|R001|Constant assigned a second time                       |`name`            |
|R002|Class variable used outside a class or module body    |—                 |
|R003|Uninitialized constant                                |`name`            |
|R004|`::` used on something that isn't a class or module   |`value`           |
|R005|Unary operator not applicable to this type            |`operator`, `type`|
|R006|Method definition with no class or module to attach to|`definition`      |
|R007|`yield` reached, but no block was passed              |`method`          |
|R008|Undefined method or variable                          |`name`            |
|R009|Modules cannot be instantiated                        |`module`          |
|R010|`require` cannot find the named module                |`path`            |

Scripts can `rescue` these. R008 raises a `NameError`, matching Ruby; the
rest raise `RuntimeError`.

Adjutant's constants are assign-once, which Ruby only warns about. R001 is
that rule firing on an ordinary constant; reopening a class or module is
U003 instead.

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

|Code|Construct                              |Placeholders     |
|----|---------------------------------------|-----------------|
|U001|`&blk` parameter capture               |`param`, `method`|
|U002|`Class.new` / `Module.new`             |`class`          |
|U003|Reopening a class or module            |`name`           |
|U004|Defining a method inside another method|`definition`     |
|U005|Calling a method by computed name      |—                |
|U006|`eval` / `instance_eval`               |—                |
|U007|Reflection into the host's internals   |—                |

U005, U006, and U007 are not yet rejected by name. Using them currently
produces an undefined-method error instead, which does not say the
construct is permanently excluded.

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

These carry no source location, since there is no script position that
would be honest to point at.

To catch them: H001, H002, and H004 are `Adjutant::HostArgumentError`,
which is an `ArgumentError`. H003 is `Adjutant::AmbiguousRiskFlowPolicyError`.

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

These carry no suggestions, because none would be honest. Instead they end
with an address to report to. Copying the whole report is genuinely useful:
the detail in it is what makes the bug findable.

The address is set by whoever ships Adjutant, so it may point at them
rather than at this project — they can triage and forward.
