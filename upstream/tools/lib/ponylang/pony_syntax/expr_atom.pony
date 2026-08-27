// The atoms of Pony's expression grammar: the things an expression bottoms
// out in.

primitive _Atom
  """
  ponyc's `atom`, `nextatom` and `caseatom` as one rule.

  They differ in which form of `(` and `[` opens a group or an array -- a
  statement admits only the newline forms -- and in whether an `if` is a
  conditional or a case's guard.
  """
  fun apply(p: Parser ref, mode: _ExprMode) =>
    let kind = p.current()
    match kind
    | TkId =>
      p.start(NdRef)
      p.bump()
      p.finish()
    | TkThis =>
      p.start(NdThis)
      p.bump()
      p.finish()
    | TkLocation =>
      p.start(NdLocation)
      p.bump()
      p.finish()
    | TkTrue | TkFalse | TkInt | TkFloat | TkString =>
      p.bump()
    | TkObject => _Object(p)
    | TkLbrace => _Lambda(p, NdLambda)
    | TkAtLbrace => _Lambda(p, NdBareLambda)
    | TkAt => _FFICall(p)
    | TkWhile => _While(p)
    | TkFor => _For(p)
    | TkIf =>
      if mode is _ExprCase then
        p.expected("an expression")
      else
        _Cond(p)
      end
    else
      if _opens_group(kind, mode) then
        _Grouped(p)
      elseif _opens_array(kind, mode) then
        _ArrayLit(p)
      else
        p.expected("an expression")
      end
    end

  fun _opens_group(kind: TokenKind, mode: _ExprMode): Bool =>
    if mode is _ExprStatement then
      kind is TkLparenNew
    else
      (kind is TkLparen) or (kind is TkLparenNew)
    end

  fun _opens_array(kind: TokenKind, mode: _ExprMode): Bool =>
    if mode is _ExprStatement then
      kind is TkLsquareNew
    else
      (kind is TkLsquare) or (kind is TkLsquareNew)
    end

primitive _Grouped
  """
  ponyc's `groupedexpr`: a parenthesised expression, or a tuple when it
  holds commas.
  """
  fun apply(p: Parser ref) =>
    p.start(NdGrouped)
    p.bump()
    let mark = p.checkpoint()
    _RawSeq(p)
    var tuple = false
    while p.at(TkComma) do
      tuple = true
      p.bump()
      _RawSeq(p)
    end
    if tuple then
      p.wrap_from(mark, NdTuple)
    end
    p.expect(TkRparen, "a closing parenthesis")
    p.finish()

primitive _ArrayLit
  """
  ponyc's `array`: `[as T: elements]`, either part optional.
  """
  fun apply(p: Parser ref) =>
    p.start(NdArray)
    p.bump()
    if p.at(TkAs) then
      p.start(NdArrayType)
      p.bump()
      _TypeRule(p)
      p.expect(TkColon, "a colon")
      p.finish()
    end
    if not p.at(TkRsquare) then
      _RawSeq(p)
    end
    p.expect(TkRsquare, "a closing bracket")
    p.finish()

primitive _FFICall
  """
  ponyc's `ffi`: `@name[R](args)`.
  """
  fun apply(p: Parser ref) =>
    p.start(NdFFICall)
    p.bump()
    p.expect_any([TkId; TkString], "an FFI name")
    if p.at(TkLsquare) then
      _TypeArgs(p)
    end
    p.expect_any(TokenSets.lparen(), "an opening parenthesis")
    if not (p.at(TkRparen) or p.at(TkWhere)) then
      _Positional(p)
    end
    if p.at(TkWhere) then
      _NamedArgs(p)
    end
    p.expect(TkRparen, "a closing parenthesis")
    if p.at(TkQuestion) then
      p.bump()
    end
    p.finish()

primitive _Object
  """
  ponyc's `object`: an anonymous type with its members.
  """
  fun apply(p: Parser ref) =>
    p.start(NdObject)
    p.bump()
    _Annotated(p)
    if p.at_any(TokenSets.caps()) then
      p.bump()
    end
    if p.at(TkIs) then
      p.start(NdProvides)
      p.bump()
      _TypeRule(p)
      p.finish()
    end
    _Members(p)
    p.expect(TkEnd, "`end`")
    p.finish()

primitive _Lambda
  """
  ponyc's `lambda` and `barelambda`, which differ only in their opening
  brace.
  """
  fun apply(p: Parser ref, kind: NodeKind) =>
    p.start(kind)
    p.bump()
    _Annotated(p)
    if p.at_any(TokenSets.caps()) then
      p.bump()
    end
    if p.at(TkId) then
      p.bump()
    end
    if p.at_any(TokenSets.lsquare()) then
      _TypeParams(p)
    end
    p.expect_any(TokenSets.lparen(), "an opening parenthesis")
    if not p.at(TkRparen) then
      _LambdaParams(p)
    end
    p.expect(TkRparen, "a closing parenthesis")
    if p.at_any(TokenSets.lparen()) then
      _LambdaCaptures(p)
    end
    if p.at(TkColon) then
      p.bump()
      _TypeRule(p)
    end
    if p.at(TkQuestion) then
      p.bump()
    end
    p.expect(TkDblarrow, "`=>`")
    _RawSeq(p)
    p.expect(TkRbrace, "a closing brace")
    if p.at_any(TokenSets.caps()) then
      p.bump()
    end
    p.finish()

primitive _LambdaParams
  fun apply(p: Parser ref) =>
    p.start(NdLambdaParams)
    _LambdaParam(p)
    while p.at(TkComma) do
      p.bump()
      _LambdaParam(p)
    end
    p.finish()

primitive _LambdaParam
  """
  ponyc's `lambdaparam`: like a method parameter, but its type may be left
  out for the context to supply.
  """
  fun apply(p: Parser ref) =>
    p.start(NdLambdaParam)
    p.expect(TkId, "a parameter name")
    if p.at(TkColon) then
      p.bump()
      _TypeRule(p)
    end
    if p.at(TkAssign) then
      _DefaultArg(p)
    end
    p.finish()

primitive _LambdaCaptures
  fun apply(p: Parser ref) =>
    p.start(NdLambdaCaptures)
    p.bump()
    _LambdaCapture(p)
    while p.at(TkComma) do
      p.bump()
      _LambdaCapture(p)
    end
    p.expect(TkRparen, "a closing parenthesis")
    p.finish()

primitive _LambdaCapture
  fun apply(p: Parser ref) =>
    if p.at(TkThis) then
      p.start(NdThis)
      p.bump()
      p.finish()
      return
    end
    p.start(NdLambdaCapture)
    p.expect(TkId, "a capture name")
    if p.at(TkColon) then
      p.bump()
      _TypeRule(p)
    end
    if p.at(TkAssign) then
      p.bump()
      _Infix(p, _ExprNormal)
    end
    p.finish()

primitive _DefaultArg
  """
  ponyc's `defaultarg`: the `= value` of a parameter.
  """
  fun apply(p: Parser ref) =>
    p.start(NdDefaultArg)
    p.bump()
    _Infix(p, _ExprNormal)
    p.finish()
