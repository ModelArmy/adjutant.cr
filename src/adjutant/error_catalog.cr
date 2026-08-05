module Adjutant
  # Every diagnostic's wording, keyed by code.
  #
  # This is the authoritative registry — `ERRORS.md` documents it for
  # readers, and a spec checks the two agree so the duplication can't
  # silently drift. Adding a diagnostic means adding an entry here AND
  # a row there; the spec fails if you do only one.
  #
  # Why the code, and not the message, is the identity:
  #
  #   - It is stable when enforcement moves phases. The nested-`def`
  #     check (U004) moved from the VM to the compiler mid-session; an
  #     identity encoding the subsystem would have had to change with
  #     it, which is not an identity.
  #   - It is a stable key for translation. A second language is a
  #     second catalog, not an audit of every raise site.
  #   - It gives specs something to assert on that survives rewording.
  #   - It gives the reader — often an LLM that generated the bad
  #     script — something to look up in ERRORS.md or a skill, rather
  #     than a sentence to pattern-match against.
  #
  # The letter encodes the KIND of problem, never the subsystem that
  # caught it:
  #
  #   P — malformed syntax
  #   C — static semantic error
  #   R — runtime fault
  #   U — deliberately unsupported (see UNSUPPORTED.md)
  #   F — IFC / risk-flow refusal
  #
  # Codes are allocated sequentially within a letter, never reused,
  # never renumbered.
  module ErrorCatalog
    # One diagnostic's wording. `summary` is the headline; `why`
    # explains the reason the construct behaves this way; `help` says
    # what to do instead. Keeping `why` and `help` separate matters
    # because they answer different questions, and a reader who
    # already knows the why still needs the how.
    #
    # All three may contain `{placeholder}`s, substituted from the
    # Diagnostic's `data`.
    #
    # Messages must be self-contained. Never reference a file in this
    # repository — a path like `SCOPE.md` means nothing to a script
    # author or to an LLM reading the output. (Learned the hard way:
    # the first draft of the 2026-07-27 enforcement messages did
    # exactly this and had to be stripped.)
    struct Entry
      getter code : String
      getter summary : String
      getter why : String?
      getter help : String?

      def initialize(@code, @summary, @why = nil, @help = nil)
      end
    end

    ENTRIES = {
      # --- C: static semantic errors --------------------------------
      "C001" => Entry.new(
        code: "C001",
        summary: "cannot assign to {target}",
        why: "The left-hand side of `=` has to name somewhere a value can " \
             "be stored: a local, an instance or class variable, a " \
             "constant, or an index like `a[0]`.",
        help: "Assign to a name or an index instead. If you meant to " \
              "compare rather than assign, use `==`."
      ),
      "C002" => Entry.new(
        code: "C002",
        summary: "`redo` outside a loop",
        why: "`redo` restarts the current iteration of the loop it appears " \
             "in, so it has no meaning where there is no loop to restart.",
        help: "Move the `redo` inside a `while`, `until`, `loop`, or `for` " \
              "body, or remove it."
      ),

      # --- R: runtime faults ----------------------------------------
      "R002" => Entry.new(
        code: "R002",
        summary: "class variable used outside a class or module body",
        why: "A class variable belongs to a class, so there has to be one " \
             "for it to belong to.",
        help: "Move it inside a `class` or `module` body, or use a local " \
              "variable or a constant instead."
      ),
      "R003" => Entry.new(
        code: "R003",
        summary: "uninitialized constant `{name}`",
        why: "No constant, class, or module by that name has been defined " \
             "at the point this ran. Constants are assign-once and defined " \
             "in order, so one defined further down the script is not " \
             "visible here yet.",
        help: "Check the spelling and capitalisation, and that `{name}` is " \
              "defined before this point."
      ),
      "R004" => Entry.new(
        code: "R004",
        summary: "`{value}` is not a class or module",
        why: "A `::` lookup needs a class or a module on its left, since " \
             "that is what holds the constant being looked up.",
        help: "Check that the name on the left of `::` refers to a class " \
              "or module."
      ),
      "R005" => Entry.new(
        code: "R005",
        summary: "`{operator}` cannot be applied to {type}",
        why: "This operator is only defined for the types that can " \
             "meaningfully support it, and {type} is not one of them.",
        help: "Convert the value first, or check that it holds what you " \
              "expected — it may be `nil` from an earlier step that " \
              "returned nothing."
      ),
      "R006" => Entry.new(
        code: "R006",
        summary: "`{definition}` has no class or module to attach to",
        why: "A method has to belong to something. Defining one requires a " \
             "class, a module, or the top-level object as its owner, and " \
             "the value acting as `self` here is none of those.",
        help: "Define the method at the top level, or inside a `class` or " \
              "`module` body."
      ),
      "R007" => Entry.new(
        code: "R007",
        summary: "no block given to `{method}`",
        why: "`{method}` reached a `yield`, which runs the block passed to " \
             "it, but it was called without one.",
        help: "Pass a block — `{method} { ... }` or `{method} do ... end`. " \
              "To make the block optional, guard the `yield` with " \
              "`block_given?`."
      ),
      "R008" => Entry.new(
        code: "R008",
        summary: "undefined method or variable `{name}`",
        why: "`{name}` is not a local variable in scope, and no method by " \
             "that name is defined on the receiver. Adjutant is a subset " \
             "of Ruby, so some methods real Ruby has may not exist here.",
        help: "Check the spelling, that the variable is assigned before " \
              "this point, and that the receiver is the type you expect."
      ),
      "R009" => Entry.new(
        code: "R009",
        summary: "`{module}` is a module and cannot be instantiated",
        why: "Modules have no instances — they exist to be included into " \
             "classes, or to namespace constants and methods.",
        help: "Instantiate a class that includes `{module}`, or call the " \
              "method on `{module}` itself if it is defined on the module."
      ),
      "R010" => Entry.new(
        code: "R010",
        summary: "cannot load `{path}`",
        why: "`require` resolves against the modules the host has " \
             "registered, not the filesystem. Nothing is registered under " \
             "that name.",
        help: "Check the spelling, and that the host registered this " \
              "module before running the script."
      ),
      "R011" => Entry.new(
        code: "R011",
        summary: "missing keyword: `{name}`",
        why: "`{method}` declares `{name}:` with no default, so a caller " \
             "must supply it by name. This call didn't.",
        help: "Pass `{name}: ...` at the call site, or give the " \
              "parameter a default (`{name}: some_value`) if it should " \
              "be optional."
      ),
      "R012" => Entry.new(
        code: "R012",
        summary: "unknown keyword: `{name}`",
        why: "`{method}` was called with `{name}:`, but it either takes " \
             "no keyword arguments at all or doesn't declare one by " \
             "that name.",
        help: "Check the spelling against `{method}`'s declared " \
              "parameters, or drop the keyword if it isn't needed."
      ),

      # --- L: limits reached ----------------------------------------
      #
      # The script is valid; it is just larger than something Adjutant
      # is prepared to handle. Distinct from `R` because the reader's
      # move is different: not "this is wrong" but "this is too much".
      # Where the ceiling is host-configurable the help says so — and
      # where it is not, it must not pretend otherwise.
      "L001" => Entry.new(
        code: "L001",
        summary: "loops nested more than {limit} deep",
        why: "Adjutant compiles at most {limit} levels of nested loop. " \
             "This is a fixed limit in the compiler, not a setting — the " \
             "loop stack it guards is a compile-time structure.",
        help: "Extract the inner loops into methods and call them, which " \
              "resets the nesting at each call."
      ),

      "L002" => Entry.new(
        code: "L002",
        summary: "call stack too deep (limit {limit})",
        why: "Each method or block call adds a frame, and {limit} were " \
             "live at once. Recursion that never reaches its base case " \
             "gets here quickly; genuinely deep call chains can too.",
        help: "Check that any recursion has a base case it actually " \
              "reaches. If the script is correct and simply needs more " \
              "depth, the host running it can raise `call_depth_limit`."
      ),
      "L003" => Entry.new(
        code: "L003",
        summary: "value stack exhausted ({limit} slots)",
        why: "Evaluating an expression pushes intermediate values onto a " \
             "fixed stack. Deeply nested expressions, or a very long " \
             "chain built in one statement, can fill it. Unlike the call " \
             "depth and instruction ceilings, this one is a fixed size " \
             "and not a setting.",
        help: "Break the expression into steps, assigning intermediate " \
              "results to variables."
      ),
      "L004" => Entry.new(
        code: "L004",
        summary: "instruction limit reached ({limit})",
        why: "The script ran {limit} instructions without finishing. A " \
             "loop whose condition never becomes false is the usual " \
             "cause, though a large amount of real work reaches the same " \
             "ceiling.",
        help: "Check that every loop can terminate. If the work is real " \
              "and simply large, the host running the script can raise " \
              "`instruction_limit`."
      ),

      "U005" => Entry.new(
        code: "U005",
        summary: "`{construct}` is not supported",
        why: "Adjutant resolves every call to a specific method before the " \
             "script runs, which is what lets a host see what a script can " \
             "do without executing it. `{construct}` picks a method by " \
             "name while running, so no such resolution is possible. This " \
             "is a permanent exclusion, not a missing feature.",
        help: "Call the method directly by name, or branch explicitly " \
              "between the calls you might make."
      ),
      "U006" => Entry.new(
        code: "U006",
        summary: "`{construct}` is not supported",
        why: "`{construct}` runs code assembled while the script is " \
             "already running, so nothing about it can be known " \
             "beforehand — a script able to do this has no meaningful " \
             "risk profile at all. This is a permanent exclusion, not a " \
             "missing feature.",
        help: "Write the code directly. There is no alternative for " \
              "running generated source; that capability is excluded by " \
              "design."
      ),
      "U007" => Entry.new(
        code: "U007",
        summary: "`{construct}` is not available",
        why: "Reflection into the interpreter's internals would let a " \
             "script reach past the boundary that native modules and " \
             "their risk profiles define. That boundary is how a host " \
             "controls what a script can do, so nothing may bypass it.",
        help: "Ask the host to register what the script legitimately " \
              "needs as a native module with a declared risk profile."
      ),

      # --- F: risk-flow refusals ------------------------------------
      #
      # Not a fault at all: the script asked for something the host's
      # policy declines to allow. Nothing is broken, and the reader may
      # well be the person who wrote the policy rather than the script.
      "F001" => Entry.new(
        code: "F001",
        summary: "risk flow policy rejected `{call}`: {reason}",
        why: "This call carries a risk label the host's policy refuses. " \
             "The refusal is the policy working as configured, not a " \
             "failure — the script asked to do something it is not " \
             "permitted to do here.",
        help: "If the call is legitimate, the policy needs a rule that " \
              "allows it. If not, the script should not be making it. " \
              "Scripts can `rescue RiskFlowRejectedError` to handle a " \
              "refusal rather than aborting."
      ),

      # --- N: a native function raised ------------------------------
      #
      # A host-registered function raised while the script called it,
      # and Adjutant has no idea why — the detail below is the host's
      # own message, passed through. Its own letter rather than an `R`
      # code because the provenance is the useful part: neither
      # Adjutant nor, necessarily, the script is at fault, and nothing
      # here can say which.
      "N001" => Entry.new(
        code: "N001",
        summary: "native function `{function}` raised: {message}",
        why: "`{function}` is provided by the host embedding Adjutant, " \
             "not by Adjutant itself. It raised while the script was " \
             "calling it, and the text above is that function's own " \
             "message, reported as-is.",
        help: "Check the arguments the script passed. If they look right, " \
              "the failure is inside the host's `{function}` and needs " \
              "reporting to whoever provides it."
      ),

      # --- H: the host misused Adjutant's API -----------------------
      #
      # Not the script's fault and not Adjutant's: whoever embedded
      # Adjutant called it wrongly. The reader is a developer with a
      # stack trace, so these carry no span — most fail before any
      # script exists, and where one is running, a position would aim
      # the reader at innocent script source.
      #
      # These deliberately do NOT share one exception class. Most are
      # about bad arguments and so are `ArgumentError`s, but an
      # ambiguous policy is about configuration state rather than any
      # one call's arguments, and claiming otherwise would be false.
      # The code classifies the failure; the class stays whatever is
      # actually accurate.
      "H001" => Entry.new(
        code: "H001",
        summary: "a RiskProfile with no tags must be reversible and Info",
        why: "An untagged profile describes a call with no risk, so it " \
             "cannot also declare itself irreversible or more severe than " \
             "informational — the two statements contradict each other.",
        help: "Add the `RiskTag` that describes the actual risk, rather " \
              "than setting `reversible` or `severity` on their own."
      ),
      "H002" => Entry.new(
        code: "H002",
        summary: "a RiskProfile with `reversible: Depends` needs a note",
        why: "`Depends` says reversibility varies by circumstance, which " \
             "is only actionable if something explains what it depends on.",
        help: "Pass `note:` describing what determines reversibility here."
      ),
      "H003" => Entry.new(
        code: "H003",
        summary: "{count} policy rules tie at priority {priority} for {target}",
        why: "Sensitivity patterns are resolved by priority, and a tie " \
             "leaves no defined answer. Adjutant refuses to guess rather " \
             "than silently pick one, since which rule wins would decide " \
             "how sensitive the data is treated as being.",
        help: "Give the intended rule a higher `priority`, or remove the " \
              "duplicate."
      ),
      "H004" => Entry.new(
        code: "H004",
        summary: "invoke_proc needs a Proc, got {found}",
        why: "`invoke_proc` runs a lambda a script produced. It has to be " \
             "given that lambda's own value — a plain object has no " \
             "callable body to run.",
        help: "Pass the Value the script returned for the lambda, " \
              "unchanged."
      ),

      "H005" => Entry.new(
        code: "H005",
        summary: "this VM has already run a chunk",
        why: "A VM holds the frames and stack of one execution. Running a " \
             "second chunk in the same one would start against whatever " \
             "the first left behind.",
        help: "Build a fresh VM per execution. `Interpreter#eval` already " \
              "does this for every call."
      ),
      "H006" => Entry.new(
        code: "H006",
        summary: "`require` needs an interpreter, and this VM has none",
        why: "`require` resolves against the modules an Interpreter " \
             "registered. A VM constructed without one has nothing to " \
             "resolve against — a supported configuration, but not one " \
             "that can load modules.",
        help: "Run the script through an `Interpreter`, or remove the " \
              "`require` if the bare VM is intentional."
      ),

      # --- I: internal invariant violations -------------------------
      #
      # These mean Adjutant is broken, not the script. None carries a
      # `help`: there is nothing the reader can do to their own code,
      # and offering a suggestion would send them editing a script
      # that was never at fault. Renderers append a report footer
      # instead — see `Diagnostic#internal?`.
      #
      # `why` here is aimed at whoever ends up DEBUGGING Adjutant, not
      # at the person who hit it: it should say enough for a
      # maintainer reading a pasted report to know where to look.
      "I001" => Entry.new(
        code: "I001",
        summary: "internal: unknown opcode {opcode}",
        why: "The VM read an instruction it has no case for. Either the " \
             "compiler emitted an opcode the VM doesn't implement, or the " \
             "bytecode was corrupted between compilation and execution."
      ),
      "I002" => Entry.new(
        code: "I002",
        summary: "internal: unpatched {target} jump target",
        why: "A forward jump was emitted with a placeholder target that " \
             "was never backpatched once its destination became known. " \
             "The compiler finished without resolving it."
      ),
      "I003" => Entry.new(
        code: "I003",
        summary: "internal: value stack underflow",
        why: "An instruction popped more values than its frame had " \
             "pushed. The compiler emitted bytecode whose stack effect " \
             "doesn't balance — this is not something a script can cause."
      ),
      "I004" => Entry.new(
        code: "I004",
        summary: "internal: builtin class `{class}` is not registered",
        why: "A literal needed its builtin class, but bootstrap had not " \
             "registered it yet. `bootstrap_builtin_classes` must run " \
             "before any script code is evaluated."
      ),
      "I006" => Entry.new(
        code: "I006",
        summary: "internal: no opcode for binary operator {operator}",
        why: "The parser produced a binary expression whose operator the " \
             "compiler has no instruction for. Usually an operator added " \
             "to the lexer and parser without a matching case in the " \
             "compiler's opcode mapping."
      ),
      "I007" => Entry.new(
        code: "I007",
        summary: "internal: no risk-aggregation case for {node}",
        why: "A risk tree contained a node kind the aggregator does not " \
             "handle. Usually a new RiskNode subtype added without a " \
             "matching case in the summarizer."
      ),
      "I005" => Entry.new(
        code: "I005",
        summary: "internal: no compiler case for AST node {node}",
        why: "The parser produced a node the compiler has no branch for. " \
             "Usually a new node type added to the AST and to the parser " \
             "without a matching case in the compiler."
      ),
      # No `why`/`help`: P001 stands in for every `expect` failure the
      # parser can have — a missing `)`, a missing `,`, a missing
      # `then`. Any explanation general enough to cover all of them
      # would be too vague to act on, and the span labels already say
      # what was wanted and where. A syntax error that DOES have
      # something general worth saying gets its own code instead —
      # see P003.
      "P001" => Entry.new(
        code: "P001",
        summary: "expected {expected}, found {found}"
      ),
      "P002" => Entry.new(
        code: "P002",
        summary: "{found} can't start an expression here"
      ),
      "P003" => Entry.new(
        code: "P003",
        summary: "`{construct}` is missing its `end`",
        why: "Every `def`, `class`, `module`, `if`, `unless`, `while`, " \
             "`until`, `for`, `case`, `begin`, `loop`, and `do` block is " \
             "closed by a matching `end`. The parser read to {found} " \
             "still looking for the one that closes this `{construct}`.",
        help: "Add the missing `end`, or check whether an `end` further " \
              "down closes the wrong construct — an `end` that arrives " \
              "too early closes the innermost block, and everything after " \
              "it then belongs to the wrong place."
      ),
      "U001" => Entry.new(
        code: "U001",
        summary: "block parameter capture (`&{param}`) is not supported",
        why: "A block passed to a method can only be run synchronously, " \
             "via `yield`, inside the call it was passed to. It never " \
             "becomes a value, so it cannot be bound to the parameter " \
             "`{param}`, stored, returned, or called later.",
        help: "Run the block with `yield` inside `{method}`, or take a " \
              "lambda as an ordinary parameter and call it with `.call`."
      ),
      "U004" => Entry.new(
        code: "U004",
        summary: "`{definition}` cannot be nested inside another method's body",
        why: "A method definition has to run exactly once, as part of " \
             "establishing a class — at the top level of a script, or " \
             "directly inside a `class`/`module` body. Nested inside " \
             "another method, it would instead run each time that method " \
             "was called, so which methods an object responds to would " \
             "depend on what had already been called on it.",
        help: "Move `{definition}` to the top level, or directly inside the " \
              "`class`/`module` body. If the behaviour needs to vary at " \
              "runtime, assign a lambda to a local or a constant instead " \
              "and call it with `.call`."
      ),
      "U002" => Entry.new(
        code: "U002",
        summary: "`{class}` cannot be instantiated",
        why: "`Class` and `Module` exist so that `.class`, `is_a?`, and " \
             "`superclass` report the truth about an object. They are not " \
             "themselves constructible: a class built at runtime would " \
             "have no name and no way to define methods on it.",
        help: "Declare the class literally instead, with `class Foo; end`."
      ),
      "U003" => Entry.new(
        code: "U003",
        summary: "`{name}` is already defined, and classes cannot be reopened",
        why: "A class or module name is a constant, and constants are " \
             "assign-once. Reopening would mean pointing `{name}` at " \
             "something new, which is exactly what that rule prevents — " \
             "it is what lets the value behind a constant be trusted " \
             "without running the script first.",
        help: "Define `{name}` once, with all of its methods in that one " \
              "body."
      ),
      "R001" => Entry.new(
        code: "R001",
        summary: "constant `{name}` is already initialized",
        why: "Constants in Adjutant are assign-once. Real Ruby only warns " \
             "here and lets the assignment through; Adjutant makes it an " \
             "error, so that whatever a constant holds can be trusted " \
             "without running the script first.",
        help: "Use a different constant, or a local variable if the value " \
              "is meant to change."
      ),
    }

    # Unknown codes render as themselves rather than raising. A
    # diagnostic about a missing diagnostic helps nobody, and a
    # reporting path that can itself explode is worse than one that
    # degrades — the consistency spec is what actually catches this,
    # at build time, where it belongs.
    def self.[](code : String) : Entry
      ENTRIES[code]? || Entry.new(
        code: code,
        summary: "unrecognized diagnostic code `#{code}`"
      )
    end

    def self.[]?(code : String) : Entry?
      ENTRIES[code]?
    end

    def self.codes : Array(String)
      ENTRIES.keys.sort!
    end

    # Names Adjutant deliberately excludes, mapped to the code that
    # says so.
    #
    # Consulted only AFTER normal resolution has failed. That ordering
    # is the whole design: a script may legitimately define its own
    # `send` — `class Mailer; def send; ...; end; end` is valid Ruby and
    # valid Adjutant — and rejecting the name at compile time, as was
    # first proposed, would break that. Reaching this table means the
    # name resolved to nothing, so the script meant Ruby's construct.
    #
    # Deliberately conservative. Every entry here is a promise that the
    # construct is excluded permanently, so only what UNSUPPORTED.md
    # actually declares belongs. `class_eval`, `instance_exec`,
    # `methods`, `instance_variable_get` and similar are plausible
    # additions but are NOT declared exclusions today — listing them
    # would tell a reader "never coming" on our own authority.
    EXCLUDED_METHODS = {
      "send"           => "U005",
      "public_send"    => "U005",
      "__send__"       => "U005",
      "method_missing" => "U005",
      "define_method"  => "U005",
      "eval"           => "U006",
      "instance_eval"  => "U006",
    }

    # Same, for constants — a different resolution path reports these.
    EXCLUDED_CONSTANTS = {
      "ObjectSpace" => "U007",
    }

    PLACEHOLDER = /\{([a-z_][a-z0-9_]*)\}/

    # Substitute `{key}` from `data`. An unmatched placeholder is left
    # verbatim rather than blanked: a visible `{param}` in the output
    # says "this diagnostic was built wrong," where silently emitting
    # an empty string produces a grammatically fine sentence that has
    # quietly lost the one detail the reader needed.
    def self.interpolate(template : String, data : Hash(String, String)) : String
      template.gsub(PLACEHOLDER) do |match|
        # `match` is the whole `{key}`; slice the braces off rather
        # than relying on `$1`, which depends on `$~` being set for
        # this block.
        data[match[1..-2]]? || match
      end
    end

    # Placeholder names used by a code's templates. The consistency
    # spec uses this to check ERRORS.md documents each one.
    def self.placeholders(code : String) : Array(String)
      entry = self[code]
      found = [] of String
      [entry.summary, entry.why, entry.help].each do |text|
        next unless text
        text.scan(PLACEHOLDER) { |match| found << match[1] }
      end
      found.uniq.sort!
    end
  end
end
