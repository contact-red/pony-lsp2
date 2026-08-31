// The control structures of Pony's expression grammar, and the atoms.

primitive _Cond
  """
  ponyc's `cond`: `if condition then ... [elseif ...] [else ...] end`.
  """
  fun apply(p: Parser ref) =>
    p.start(NdIf)
    p.bump()
    _Annotated(p)
    _RawSeq(p)
    p.expect(TkThen, "`then`")
    _RawSeq(p)
    _ElseTail(p, TkIf)
    p.expect(TkEnd, "`end`")
    p.finish()

primitive _IfDef
  """
  ponyc's `ifdef`: the same shape over build flags.
  """
  fun apply(p: Parser ref) =>
    p.start(NdIfDef)
    p.bump()
    _Annotated(p)
    _Infix(p, _ExprNormal)
    p.expect(TkThen, "`then`")
    _RawSeq(p)
    _ElseTail(p, TkIfdef)
    p.expect(TkEnd, "`end`")
    p.finish()

primitive _ElseTail
  """
  The `elseif ... then ...` chain and `else ...` that close a conditional.

  ponyc writes the chain as a rule that recurses into itself; the shape is
  the same either way, and a loop keeps the tree flat rather than nesting
  one `elseif` inside the last.
  """
  fun apply(p: Parser ref, chain_kind: TokenKind) =>
    while p.at(TkElseif) do
      p.start(if chain_kind is TkIfdef then NdIfDef else NdIf end)
      p.bump()
      _Annotated(p)
      if chain_kind is TkIfdef then
        _Infix(p, _ExprNormal)
      else
        _RawSeq(p)
      end
      p.expect(TkThen, "`then`")
      _RawSeq(p)
      p.finish()
    end
    _ElseClause(p)

primitive _ElseClause
  fun apply(p: Parser ref) =>
    if p.at(TkElse) then
      p.start(NdElse)
      p.bump()
      _Annotated(p)
      _RawSeq(p)
      p.finish()
    end

primitive _IfTypeSet
  """
  ponyc's `iftypeset`: `iftype T <: U then ... [elseif ...] [else ...] end`.
  """
  fun apply(p: Parser ref) =>
    p.start(NdIfTypeSet)
    p.bump()
    _Annotated(p)
    _IfTypeClause(p)
    while p.at(TkElseif) do
      p.bump()
      _Annotated(p)
      _IfTypeClause(p)
    end
    _ElseClause(p)
    p.expect(TkEnd, "`end`")
    p.finish()

primitive _IfTypeClause
  fun apply(p: Parser ref) =>
    p.start(NdIfType)
    _TypeRule(p)
    p.expect(TkSubtype, "`<:`")
    _TypeRule(p)
    p.expect(TkThen, "`then`")
    _RawSeq(p)
    p.finish()

primitive _Match
  """
  ponyc's `match`: a subject, cases, and an optional else.
  """
  fun apply(p: Parser ref) =>
    p.start(NdMatch)
    p.bump()
    _Annotated(p)
    _RawSeq(p)
    p.start(NdCases)
    while p.at(TkPipe) do
      _Case(p)
    end
    p.finish()
    _ElseClause(p)
    p.expect(TkEnd, "`end`")
    p.finish()

primitive _Case
  """
  ponyc's `caseexpr`: `| pattern [if guard] [=> body]`.
  """
  fun apply(p: Parser ref) =>
    p.start(NdCase)
    p.bump()
    _Annotated(p)
    if not (p.at(TkIf) or p.at(TkDblarrow) or p.at(TkPipe) or
      p.at(TkElse) or p.at(TkEnd))
    then
      _Pattern(p, _ExprCase)
    end
    if p.at(TkIf) then
      p.start(NdGuard)
      p.bump()
      _RawSeq(p)
      p.finish()
    end
    if p.at(TkDblarrow) then
      p.bump()
      _RawSeq(p)
    end
    p.finish()

primitive _While
  fun apply(p: Parser ref) =>
    p.start(NdWhile)
    p.bump()
    _Annotated(p)
    _RawSeq(p)
    p.expect(TkDo, "`do`")
    _RawSeq(p)
    _ElseClause(p)
    p.expect(TkEnd, "`end`")
    p.finish()

primitive _Repeat
  fun apply(p: Parser ref) =>
    p.start(NdRepeat)
    p.bump()
    _Annotated(p)
    _RawSeq(p)
    p.expect(TkUntil, "`until`")
    _Annotated(p)
    _RawSeq(p)
    _ElseClause(p)
    p.expect(TkEnd, "`end`")
    p.finish()

primitive _For
  fun apply(p: Parser ref) =>
    p.start(NdFor)
    p.bump()
    _Annotated(p)
    _IdSeq(p)
    p.expect(TkIn, "`in`")
    _RawSeq(p)
    p.expect(TkDo, "`do`")
    _RawSeq(p)
    _ElseClause(p)
    p.expect(TkEnd, "`end`")
    p.finish()

primitive _With
  fun apply(p: Parser ref) =>
    p.start(NdWith)
    p.bump()
    _Annotated(p)
    _WithElem(p)
    while p.at(TkComma) do
      p.bump()
      _WithElem(p)
    end
    p.expect(TkDo, "`do`")
    _RawSeq(p)
    p.expect(TkEnd, "`end`")
    p.finish()

primitive _WithElem
  fun apply(p: Parser ref) =>
    p.start(NdWithElem)
    _IdSeq(p)
    p.expect(TkAssign, "an equals sign")
    _RawSeq(p)
    p.finish()

primitive _IdSeq
  """
  ponyc's `idseq`: the names a `for` or a `with` binds, one or a tuple.
  """
  fun apply(p: Parser ref) =>
    // Recurses through _IdSeqName without passing the sequence or term
    // rules, so it carries its own descent.
    if p.too_deep("expression") then
      return
    end
    p.start(NdIdSeq)
    if p.at_any(TokenSets.lparen()) then
      p.bump()
      _IdSeqName(p)
      while p.at(TkComma) do
        p.bump()
        _IdSeqName(p)
      end
      p.expect(TkRparen, "a closing parenthesis")
    else
      _IdSeqName(p)
    end
    p.finish()
    p.ascend()

primitive _IdSeqName
  fun apply(p: Parser ref) =>
    if p.at_any(TokenSets.lparen()) then
      _IdSeq(p)
    else
      p.expect(TkId, "a variable name")
    end

primitive _Try
  fun apply(p: Parser ref) =>
    p.start(NdTry)
    p.bump()
    _Annotated(p)
    _RawSeq(p)
    _ElseClause(p)
    if p.at(TkThen) then
      p.start(NdThen)
      p.bump()
      _Annotated(p)
      _RawSeq(p)
      p.finish()
    end
    p.expect(TkEnd, "`end`")
    p.finish()

primitive _Recover
  fun apply(p: Parser ref) =>
    p.start(NdRecover)
    p.bump()
    _Annotated(p)
    if p.at_any(TokenSets.caps()) then
      p.bump()
    end
    _RawSeq(p)
    p.expect(TkEnd, "`end`")
    p.finish()

primitive _Consume
  fun apply(p: Parser ref) =>
    p.start(NdConsume)
    p.bump()
    if p.at_any(TokenSets.caps()) then
      p.bump()
    end
    _Term(p, _ExprNormal)
    p.finish()

primitive _Annotated
  """
  The `\\annotation\\` that may follow a control keyword.
  """
  fun apply(p: Parser ref) =>
    if p.at(TkBackslash) then
      _Annotations(p)
    end
