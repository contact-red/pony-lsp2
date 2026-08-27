primitive _ExprNormal
  """
  An expression in the ordinary position.
  """

primitive _ExprStatement
  """
  An expression starting a statement, where the one before it ended
  without a semicolon.

  Only the newline forms of `(`, `[` and `-` may open one. `f\n(x)` is a
  call on one line and two statements on two, and the lexer has already
  decided which by giving the token its newline form.
  """

primitive _ExprCase
  """
  A `match` case pattern, where an `if` is the case's guard rather than a
  conditional expression.
  """

type _ExprMode is (_ExprNormal | _ExprStatement | _ExprCase)
  """
  Which alternatives an expression rule admits.

  ponyc writes these as separate rules -- `atom`, `nextatom`, `caseatom`,
  and the same again for prefix, postfix, term, infix and assignment --
  because its grammar is a macro DSL with no way to pass a parameter. They
  differ only in which alternatives they list, so here they are one rule
  and a parameter.
  """
