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

  fun nesting_close(): Array[TokenKind] val =>
    """
    The tokens that close a nested region.
    """
    [TkRparen; TkRsquare; TkRbrace; TkEnd; TkEof]

  fun field_start(): Array[TokenKind] val =>
    [TkVar; TkLet; TkEmbed]

  fun method_start(): Array[TokenKind] val =>
    [TkFun; TkBe; TkNew]

  fun member_or_top_level(): Array[TokenKind] val =>
    """
    Where a member list ends: the next member, the next item, or the `end`
    that closes an `object` literal.
    """
    [ TkVar; TkLet; TkEmbed; TkFun; TkBe; TkNew
      TkUse; TkType; TkInterface; TkTrait
      TkPrimitive; TkStruct; TkClass; TkActor
      TkEnd ]

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

