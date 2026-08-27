primitive TokenSets
  """
  The token sets the grammar tests against, in one place because several
  rules share them and because they are what bounds the cost of an error.
  """
  fun top_level(): Array[TokenKind] val =>
    """
    What a top-level item can start with. ponyc's `RESTART` set for both
    `use` and `class_def`, and the resync point for anything that fails.
    """
    [ TkUse; TkType; TkInterface; TkTrait
      TkPrimitive; TkStruct; TkClass; TkActor ]

  fun field_start(): Array[TokenKind] val =>
    [TkVar; TkLet; TkEmbed]

  fun method_start(): Array[TokenKind] val =>
    [TkFun; TkBe; TkNew]

  fun member_start(): Array[TokenKind] val =>
    [TkVar; TkLet; TkEmbed; TkFun; TkBe; TkNew]

  fun method_or_top_level(): Array[TokenKind] val =>
    """
    Where a method body ends.

    Deliberately without `var`, `let` and `embed`: those start a local
    declaration, and a body is full of them. Stopping there would end every
    body at its first local and leave the rest of it to be read as fields.
    """
    [ TkFun; TkBe; TkNew
      TkUse; TkType; TkInterface; TkTrait
      TkPrimitive; TkStruct; TkClass; TkActor ]

  fun member_or_top_level(): Array[TokenKind] val =>
    [ TkVar; TkLet; TkEmbed; TkFun; TkBe; TkNew
      TkUse; TkType; TkInterface; TkTrait
      TkPrimitive; TkStruct; TkClass; TkActor ]

  fun caps(): Array[TokenKind] val =>
    [TkIso; TkTrn; TkRef; TkVal; TkBox; TkTag]

  fun gencaps(): Array[TokenKind] val =>
    [TkCapRead; TkCapSend; TkCapShare; TkCapAlias; TkCapAny]

  fun any_cap(): Array[TokenKind] val =>
    [ TkIso; TkTrn; TkRef; TkVal; TkBox; TkTag
      TkCapRead; TkCapSend; TkCapShare; TkCapAlias; TkCapAny ]

  fun literals(): Array[TokenKind] val =>
    [TkTrue; TkFalse; TkInt; TkFloat; TkString]

  fun entities(): Array[TokenKind] val =>
    [ TkType; TkInterface; TkTrait; TkPrimitive
      TkStruct; TkClass; TkActor ]

  fun lparen(): Array[TokenKind] val =>
    """
    Pony distinguishes a `(` that follows a newline, so both forms have to
    be accepted wherever an open parenthesis is expected.
    """
    [TkLparen; TkLparenNew]

  fun lsquare(): Array[TokenKind] val =>
    [TkLsquare; TkLsquareNew]

  fun block_open(): Array[TokenKind] val =>
    """
    Tokens that open a region closed by `end`. Needed by the body skeleton,
    which must not stop at a `fun` that belongs to an `object` literal.
    """
    // `iftype` lexes as TkIftypeSet, not TkIftype -- ponyc's keyword table
    // maps the word to TK_IFTYPE_SET and reserves TK_IFTYPE for a node its
    // parser builds. Using the wrong one leaves every `iftype` uncounted
    // and its `end` looking unbalanced.
    [ TkIf; TkIfdef; TkIftypeSet; TkWhile; TkFor; TkRepeat
      TkTry; TkMatch; TkRecover; TkObject; TkWith ]

  fun bracket_open(): Array[TokenKind] val =>
    [TkLparen; TkLparenNew; TkLsquare; TkLsquareNew; TkLbrace; TkAtLbrace]

  fun closers(): Array[TokenKind] val =>
    [TkEnd; TkRparen; TkRsquare; TkRbrace]
