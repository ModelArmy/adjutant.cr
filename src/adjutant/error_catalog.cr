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
