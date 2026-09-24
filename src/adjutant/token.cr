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
    # `include` and `extend` are ordinary method calls, not keywords.
    # `prepend` is reserved but not implemented.
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
    TripleEq # ===, def-name position AND infix (a === b) — see scan_eq's own comment
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

    # True when whitespace or a comment precedes this token. The
    # parser uses it for Ruby's spacing-sensitive rules, such as
    # `eq -1, -1` against `n - 1`.
    getter? space_before : Bool

    # The flag letters after a regex literal's closing `/` (a subset
    # of "imx"), set only on Regex and RegexEnd tokens. `lexeme` holds
    # the pattern text alone.
    getter regex_flags : String

    def initialize(@kind, @lexeme, @line, @column, @space_before = false, @regex_flags = "")
    end

    def to_s(io : IO) : Nil
      io << kind << "(" << lexeme.inspect << ")@" << line << ":" << column
    end
  end
end
