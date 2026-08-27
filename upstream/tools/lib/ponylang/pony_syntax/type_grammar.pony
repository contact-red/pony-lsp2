// Pony's type grammar, ported rule for rule from ponyc's parser.c.
//
// The one systematic departure: ponyc's INFIX_BUILD rebuilds the tree around
// an operator, making `A | B` a union node with two children. This tree is
// source-ordered, so the operator stays between its operands and the rule
// wraps them instead. See `Parser.wrap_from`.

primitive _TypeRule
  """
  ponyc's `type`: an atom, optionally followed by a viewpoint.
  """
  fun apply(p: Parser ref) =>
    let mark = p.checkpoint()
    _AtomType(p)
    if p.at(TkArrow) then
      p.bump()
      _TypeRule(p)
      p.wrap_from(mark, NdViewpoint)
    end

primitive _InfixType
  """
  ponyc's `infixtype`: types joined by `|` or `&`.
  """
  fun apply(p: Parser ref) =>
    let mark = p.checkpoint()
    _TypeRule(p)
    var joined = false
    while p.at(TkPipe) or p.at(TkIsecttype) do
      joined = true
      p.bump()
      _TypeRule(p)
    end
    if joined then
      p.wrap_from(mark, NdInfixType)
    end

primitive _AtomType
  """
  ponyc's `atomtype`: `this`, a capability, a parenthesised type, a named
  type, or a lambda type.
  """
  fun apply(p: Parser ref) =>
    if p.at(TkThis) then
      p.start(NdThisType)
      p.bump()
      p.finish()
    elseif p.at_any(TokenSets.any_cap()) then
      p.bump()
    elseif p.at_any(TokenSets.lparen()) then
      _GroupedType(p)
    elseif p.at(TkId) then
      _Nominal(p)
    elseif p.at(TkLbrace) then
      _LambdaType(p, NdLambdaType)
    elseif p.at(TkAtLbrace) then
      _LambdaType(p, NdBareLambdaType)
    else
      p.expected("a type")
    end

primitive _Nominal
  """
  ponyc's `nominal`: `[package.]Name[typeargs][cap][^ or !]`.
  """
  fun apply(p: Parser ref) =>
    p.start(NdNominal)
    p.bump()
    if p.at(TkDot) then
      p.bump()
      p.expect(TkId, "a type name")
    end
    if p.at(TkLsquare) then
      _TypeArgs(p)
    end
    if p.at_any(TokenSets.any_cap()) then
      p.bump()
    end
    if p.at(TkEphemeral) or p.at(TkAliased) then
      p.bump()
    end
    p.finish()

primitive _GroupedType
  """
  ponyc's `groupedtype`: `(infixtype[, infixtype]*)`.

  A comma makes it a tuple, which is not known until the comma appears.
  """
  fun apply(p: Parser ref) =>
    p.start(NdGroupedType)
    p.bump()
    let mark = p.checkpoint()
    _InfixType(p)
    var tuple = false
    while p.at(TkComma) do
      tuple = true
      p.bump()
      _InfixType(p)
    end
    if tuple then
      p.wrap_from(mark, NdTupleType)
    end
    p.expect(TkRparen, "a closing parenthesis")
    p.finish()

primitive _LambdaType
  """
  ponyc's `lambdatype` and `barelambdatype`, which differ only in whether
  they open with `{` or `@{`.
  """
  fun apply(p: Parser ref, kind: NodeKind) =>
    p.start(kind)
    p.bump()
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
      _TypeList(p)
    end
    p.expect(TkRparen, "a closing parenthesis")
    if p.at(TkColon) then
      p.bump()
      _TypeRule(p)
    end
    if p.at(TkQuestion) then
      p.bump()
    end
    p.expect(TkRbrace, "a closing brace")
    if p.at_any(TokenSets.any_cap()) then
      p.bump()
    end
    if p.at(TkEphemeral) or p.at(TkAliased) then
      p.bump()
    end
    p.finish()

primitive _TypeList
  """
  ponyc's `typelist`: the parameter types of a lambda type.
  """
  fun apply(p: Parser ref) =>
    p.start(NdTypeList)
    _TypeRule(p)
    while p.at(TkComma) do
      p.bump()
      _TypeRule(p)
    end
    p.finish()

primitive _TypeArgs
  """
  ponyc's `typeargs`: `[typearg[, typearg]*]` at a use site.

  Only `[` opens one, never the newline form: a `[` on a new line starts an
  array literal, not type arguments.
  """
  fun apply(p: Parser ref) =>
    p.start(NdTypeArgs)
    p.bump()
    _TypeArg(p)
    while p.at(TkComma) do
      p.bump()
      _TypeArg(p)
    end
    p.expect(TkRsquare, "a closing bracket")
    p.finish()

primitive _TypeArg
  """
  ponyc's `typearg`: a type, a literal, or a `#`-prefixed constant.
  """
  fun apply(p: Parser ref) =>
    if p.at_any(TokenSets.literals()) then
      p.start(NdValueFormalArg)
      p.bump()
      p.finish()
    elseif p.at(TkConstant) then
      p.start(NdValueFormalArg)
      p.start(NdConstExpr)
      p.bump()
      Skeleton(p, [TkComma; TkRsquare])
      p.finish()
      p.finish()
    else
      _TypeRule(p)
    end

primitive _TypeParams
  """
  ponyc's `typeparams`: `[typeparam[, typeparam]*]` on a declaration.

  Both forms of `[` open one, because a declaration's type parameters can
  begin a line.
  """
  fun apply(p: Parser ref) =>
    p.start(NdTypeParams)
    p.bump()
    _TypeParam(p)
    while p.at(TkComma) do
      p.bump()
      _TypeParam(p)
    end
    p.expect(TkRsquare, "a closing bracket")
    p.finish()

primitive _TypeParam
  """
  ponyc's `typeparam`: a name, an optional constraint, an optional default.
  """
  fun apply(p: Parser ref) =>
    p.start(NdTypeParam)
    p.expect(TkId, "a type parameter name")
    if p.at(TkColon) then
      p.bump()
      _TypeRule(p)
    end
    if p.at(TkAssign) then
      p.bump()
      _TypeArg(p)
    end
    p.finish()
