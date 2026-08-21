module Adjutant
  enum TokenKind
    # Control
    EOF
    Error
    Newline

    # Literals
    Identifier
    Constant # Starts with uppercase
    IVar     # @name
    CVar     # @@name
    GVar     # $name
    Integer
    Float
    String
    StringPart  # segment before/between #{} interpolations
    StringEnd   # final segment after last interpolation
    InterpStart # #{
    InterpEnd   # } closing an interpolation
    Symbol
    Regex          # /pattern/flags with no interpolation
    RegexPart      # segment before/between #{} interpolations, inside /.../
    RegexEnd       # final segment after last interpolation, /.../flags
    PercentWords   # %w[...] raw body — parser splits into an ArrayLiteral of StringLiteral
    PercentSymbols # %i[...] raw body — parser splits into an ArrayLiteral of SymbolLiteral

    # Keywords
    KwClass
    KwModule
    KwDef
    KwEnd
    KwIf
    KwElsif
    KwElse
    KwUnless
    KwWhile
    KwUntil
    KwLoop
    KwFor
    KwIn
    KwCase
    KwWhen
    KwThen
    KwDo
    KwYield
    KwReturn
    KwBreak
    KwNext
    KwRedo
    KwSuper
    KwSelf
    KwTrue
    KwFalse
    KwNil
    KwAnd
    KwOr
    KwNot
    KwBegin
    KwRescue
    KwEnsure
    KwRaise
    KwRetry
    KwRequire
    KwLoad
    # KwInclude deliberately removed 2026-08-10 (see SCOPE.md's git
    # history) — unlike prepend below, `include` needs no new
    # grammar at all: `include Foo` is just an ordinary bare method
    # call (`Module#include`, real Ruby), and Adjutant's class/module
    # body dispatch already resolves bare calls against Module's own
    # method chain correctly (VM#dispatch_call's self_rclass branch).
    # Keeping it reserved would have forced every `include Foo` to hit
    # a parse error before ever reaching that already-working
    # mechanism. KwExtend removed 2026-08-10 too, once `extend` itself
    # was actually built — identical reasoning, `extend` is equally an
    # ordinary Module method, not a keyword. prepend stays reserved
    # for now — not implemented yet, and reserving it costs nothing
    # until it is.
    KwPrepend
    KwAttrReader
    KwAttrWriter
    KwAttrAccessor
    KwFile       # __FILE__
    KwLine       # __LINE__
    KwMethodName # __method__
    KwCalleeName # __callee__
    KwPrivate
    KwPublic
    KwProtected
    KwModuleFunction
    KwAlias

    # Punctuation
    LParen
    RParen
    LBrace
    RBrace
    LBracket
    RBracket
    Comma
    Dot
    Colon
    Semi
    Pipe
    Amp
    Plus
    Minus
    Star
    Slash
    Percent
    Caret
    Bang
    Tilde
    EqTilde   # =~, regex/string match — see scan_eq's own comment
    BangTilde # !~, negated match — see scan's own comment on '!'
    Eq
    EqEq
    TripleEq # ===, def-name position only — see scan_eq's own comment
    NEq
    Lt
    LtE
    Gt
    GtE
    AndAnd
    OrOr
    Shl
    Shr
    Question
    HashRocket # =>
    RangeIncl  # ..
    RangeExcl  # ...
    SafeNav    # &.
    ColonColon # ::
    PlusEq     # +=
    MinusEq    # -=
    StarEq     # *=
    SlashEq    # /=
    PercentEq  # %=
    OrAssign   # ||=
    AndAssign  # &&=
    Arrow      # ->
    Spaceship  # <=>
  end

  # Maps keyword strings to their TokenKind.
  KEYWORDS = {
    "class"           => TokenKind::KwClass,
    "module"          => TokenKind::KwModule,
    "def"             => TokenKind::KwDef,
    "end"             => TokenKind::KwEnd,
    "if"              => TokenKind::KwIf,
    "elsif"           => TokenKind::KwElsif,
    "else"            => TokenKind::KwElse,
    "unless"          => TokenKind::KwUnless,
    "while"           => TokenKind::KwWhile,
    "until"           => TokenKind::KwUntil,
    "loop"            => TokenKind::KwLoop,
    "for"             => TokenKind::KwFor,
    "in"              => TokenKind::KwIn,
    "case"            => TokenKind::KwCase,
    "when"            => TokenKind::KwWhen,
    "then"            => TokenKind::KwThen,
    "do"              => TokenKind::KwDo,
    "yield"           => TokenKind::KwYield,
    "return"          => TokenKind::KwReturn,
    "break"           => TokenKind::KwBreak,
    "next"            => TokenKind::KwNext,
    "redo"            => TokenKind::KwRedo,
    "super"           => TokenKind::KwSuper,
    "self"            => TokenKind::KwSelf,
    "true"            => TokenKind::KwTrue,
    "false"           => TokenKind::KwFalse,
    "nil"             => TokenKind::KwNil,
    "and"             => TokenKind::KwAnd,
    "or"              => TokenKind::KwOr,
    "not"             => TokenKind::KwNot,
    "begin"           => TokenKind::KwBegin,
    "rescue"          => TokenKind::KwRescue,
    "ensure"          => TokenKind::KwEnsure,
    "raise"           => TokenKind::KwRaise,
    "retry"           => TokenKind::KwRetry,
    "require"         => TokenKind::KwRequire,
    "load"            => TokenKind::KwLoad,
    "prepend"         => TokenKind::KwPrepend,
    "attr_reader"     => TokenKind::KwAttrReader,
    "attr_writer"     => TokenKind::KwAttrWriter,
    "attr_accessor"   => TokenKind::KwAttrAccessor,
    "__FILE__"        => TokenKind::KwFile,
    "__LINE__"        => TokenKind::KwLine,
    "__method__"      => TokenKind::KwMethodName,
    "__callee__"      => TokenKind::KwCalleeName,
    "private"         => TokenKind::KwPrivate,
    "public"          => TokenKind::KwPublic,
    "protected"       => TokenKind::KwProtected,
    "module_function" => TokenKind::KwModuleFunction,
    "alias"           => TokenKind::KwAlias,
  }

  struct Token
    getter kind : TokenKind
    getter lexeme : String
    getter line : Int32
    getter column : Int32

    # True when this token was preceded by whitespace (spaces/tabs) or
    # a comment, i.e. it does NOT immediately abut the previous token.
    # This is the one piece of context Adjutant's lexer previously
    # discarded entirely (see `Lexer#skip_whitespace_and_comments`) that
    # the parser had to reconstruct after the fact via column
    # arithmetic for every whitespace-sensitive Ruby-compatibility rule
    # (`eq -1, -1` vs `n - 1`, `-0.0.to_s` literal fusion, `eq (6/3), 2`
    # bare-call-with-parenthesized-first-arg). Capturing it once, here,
    # replaces those bespoke per-callsite column checks with a single
    # source of truth. Defaults to `false` so every existing
    # `Token.new(...)` call site (none of which pass this) keeps
    # compiling unchanged — only call sites that care about spacing
    # need to pass it explicitly.
    getter? space_before : Bool

    # Trailing flag letters (some subset of "imx") captured off the
    # closing `/` of a regex literal — e.g. the "i" in `/abc/i`. Only
    # ever set on TokenKind::Regex and TokenKind::RegexEnd; every
    # other token kind leaves this at its default "". Not folded into
    # `lexeme` (which stays exactly the pattern text) because the
    # parser needs the two pieces separately: pattern text becomes
    # Regexp.new's first argument, flags become its second — same
    # split real Ruby's own Regexp::IGNORECASE/MULTILINE/EXTENDED
    # options represent.
    getter regex_flags : String

    def initialize(@kind, @lexeme, @line, @column, @space_before = false, @regex_flags = "")
    end

    def to_s(io : IO) : Nil
      io << kind << "(" << lexeme.inspect << ")@" << line << ":" << column
    end
  end
end
