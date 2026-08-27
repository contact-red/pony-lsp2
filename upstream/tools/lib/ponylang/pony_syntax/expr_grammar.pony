// Pony's expression grammar, ported rule for rule from ponyc's parser.c.
//
// Two systematic departures, both because this builds a source-ordered tree
// rather than an AST for later passes. INFIX_BUILD rebuilds the tree around
// an operator; here the operator stays between its operands and the rule
// wraps them, with `Parser.wrap_from`. REORDER puts a rule's children in the
// order a later pass wants; here they stay in the order they were written.
//
// ponyc's `test_*` rules are omitted. They exist for `$`-prefixed symbols
// that only its own test suite uses, and are enabled by a flag this parser
// does not offer.

primitive _RawSeq
  """
  ponyc's `rawseq`: one or more expressions, separated by semicolons or by
  nothing at all.
  """
  fun apply(p: Parser ref) =>
    p.start(NdSeq)
    _Statement(p, _ExprNormal)
    while not _SeqEnd(p.current()) do
      let before = p.pos()
      if p.at(TkSemi) then
        p.bump()
        if _SeqEnd(p.current()) then
          break
        end
        _Statement(p, _ExprNormal)
      else
        // No semicolon, so this begins a statement, and only the newline
        // forms of `(`, `[` and `-` may open one.
        _Statement(p, _ExprStatement)
      end
      if p.pos() == before then
        // The token here starts no expression and ends no sequence, so
        // nothing was consumed and going around again would spin. The rule
        // that failed has already said what it expected; take the token as
        // an error and carry on, so that no input can hang the parser.
        p.start(NdError)
        p.bump()
        p.finish()
      end
    end
    p.finish()

primitive _SeqEnd
  """
  Whether a token ends a sequence of expressions rather than starting
  another one.

  Not `var`, `let` or `embed`: those begin a local declaration, which is an
  expression. `fun`, `be` and `new` do end one, and cannot appear inside an
  expression except within an `object` literal, which is consumed to its
  `end` before this is asked.
  """
  fun apply(kind: TokenKind): Bool =>
    match kind
    | TkEnd | TkElse | TkElseif | TkThen | TkDo | TkUntil | TkPipe
    | TkRparen | TkRsquare | TkRbrace | TkComma | TkWhere | TkDblarrow
    | TkEof
    | TkFun | TkBe | TkNew
    | TkUse | TkType | TkInterface | TkTrait
    | TkPrimitive | TkStruct | TkClass | TkActor => true
    else
      false
    end

primitive _Statement
  """
  ponyc's `assignment` or `jump`, whichever the next token begins.
  """
  fun apply(p: Parser ref, mode: _ExprMode) =>
    if _IsJump(p.current()) then
      _Jump(p)
    else
      _Assignment(p, mode)
    end

primitive _IsJump
  fun apply(kind: TokenKind): Bool =>
    match kind
    | TkReturn | TkBreak | TkContinue | TkError
    | TkCompileIntrinsic | TkCompileError => true
    else
      false
    end

primitive _Jump
  """
  ponyc's `jump`: a control transfer and, for some of them, a value.
  """
  fun apply(p: Parser ref) =>
    p.start(NdJump)
    p.bump()
    if not _SeqEnd(p.current()) then
      _RawSeq(p)
    end
    p.finish()

primitive _Assignment
  """
  ponyc's `assignment`: an infix expression, optionally assigned to.
  """
  fun apply(p: Parser ref, mode: _ExprMode) =>
    let mark = p.checkpoint()
    _Infix(p, mode)
    if p.at(TkAssign) then
      p.bump()
      _Assignment(p, _ExprNormal)
      p.wrap_from(mark, NdAssign)
    end

primitive _Infix
  """
  ponyc's `infix`: terms joined by binary operators, `is`, `isnt` or `as`.

  Pony gives infix operators no precedence -- the parentheses are the
  precedence -- so each operator simply takes everything to its left,
  nesting `a + b + c` to the left as ponyc's INFIX_BUILD does.
  """
  fun apply(p: Parser ref, mode: _ExprMode) =>
    let mark = p.checkpoint()
    _Term(p, mode)
    var going = true
    while going do
      if p.at(TkAs) then
        p.bump()
        _TypeRule(p)
        p.wrap_from(mark, NdAsOp)
      elseif p.at(TkIs) or p.at(TkIsnt) or _IsBinOp(p.current()) then
        p.bump()
        // A partial operator: `a +? b`.
        if p.at(TkQuestion) then
          p.bump()
        end
        _Term(p, _ExprNormal)
        p.wrap_from(mark, NdBinOp)
      else
        going = false
      end
    end

primitive _IsBinOp
  fun apply(kind: TokenKind): Bool =>
    match kind
    | TkAnd | TkOr | TkXor
    | TkPlus | TkMinus | TkMultiply | TkDivide | TkRem | TkMod
    | TkPlusTilde | TkMinusTilde | TkMultiplyTilde | TkDivideTilde
    | TkRemTilde | TkModTilde
    | TkLshift | TkRshift | TkLshiftTilde | TkRshiftTilde
    | TkEq | TkNe | TkLt | TkLe | TkGe | TkGt
    | TkEqTilde | TkNeTilde | TkLtTilde | TkLeTilde | TkGeTilde
    | TkGtTilde => true
    else
      false
    end

primitive _Term
  """
  ponyc's `term`: a control structure, a `consume`, or a pattern.
  """
  fun apply(p: Parser ref, mode: _ExprMode) =>
    let kind = p.current()
    match kind
    | TkIf =>
      // In a case pattern an `if` is the case's guard, not a conditional.
      if mode is _ExprCase then
        _Pattern(p, mode)
      else
        _Cond(p)
      end
    | TkIfdef => _IfDef(p)
    | TkIftypeSet => _IfTypeSet(p)
    | TkMatch => _Match(p)
    | TkWhile => _While(p)
    | TkRepeat => _Repeat(p)
    | TkFor => _For(p)
    | TkWith => _With(p)
    | TkTry => _Try(p)
    | TkRecover => _Recover(p)
    | TkConsume => _Consume(p)
    | TkConstant => _ConstExpr(p)
    else
      _Pattern(p, mode)
    end

primitive _Pattern
  """
  ponyc's `pattern`: a local declaration, or an expression.
  """
  fun apply(p: Parser ref, mode: _ExprMode) =>
    match p.current()
    | TkVar | TkLet | TkEmbed | TkMatchCapture => _Local(p)
    else
      _ParamPattern(p, mode)
    end

primitive _Local
  """
  ponyc's `local`: `var`, `let`, `embed` or a match capture, and its name.
  """
  fun apply(p: Parser ref) =>
    p.start(NdLocal)
    p.bump()
    p.expect(TkId, "a variable name")
    if p.at(TkColon) then
      p.bump()
      _TypeRule(p)
    end
    p.finish()

primitive _ParamPattern
  """
  ponyc's `parampattern`: a prefix operator applied to one, or a postfix
  expression.
  """
  fun apply(p: Parser ref, mode: _ExprMode) =>
    if _IsPrefixOp(p.current(), mode) then
      p.start(NdUnaryOp)
      p.bump()
      _ParamPattern(p, _ExprNormal)
      p.finish()
    else
      _Postfix(p, mode)
    end

primitive _IsPrefixOp
  """
  Whether a token is a prefix operator here.

  A statement may open with the newline form of `-` and not the ordinary
  one, which is what stops `a\n-b` reading as a subtraction.
  """
  fun apply(kind: TokenKind, mode: _ExprMode): Bool =>
    match kind
    | TkNot | TkAddress | TkDigestof
    | TkMinusNew | TkMinusTildeNew => true
    | TkMinus | TkMinusTilde => not (mode is _ExprStatement)
    else
      false
    end

primitive _Postfix
  """
  ponyc's `postfix`: an atom, then any number of `.`, `~`, `.>`, type
  arguments and calls applied to it.
  """
  fun apply(p: Parser ref, mode: _ExprMode) =>
    let mark = p.checkpoint()
    _Atom(p, mode)

    // Each operator wraps everything so far, so `x.y.z(k)` nests to the
    // left as ponyc's INFIX_BUILD does: the receiver of `.z` is `x.y`, and
    // the receiver of the call is `x.y.z`. That nesting is what lets a
    // question about `.y` be answered without re-parsing the chain.
    var going = true
    while going do
      if p.at(TkDot) or p.at(TkTilde) or p.at(TkChain) then
        let kind =
          if p.at(TkDot) then NdDot
          elseif p.at(TkTilde) then NdTilde
          else NdChain
          end
        p.bump()
        p.expect(TkId, "a member name")
        p.wrap_from(mark, kind)
      elseif p.at(TkLsquare) then
        _TypeArgs(p)
        p.wrap_from(mark, NdQualify)
      elseif p.at(TkLparen) then
        _Call(p)
        p.wrap_from(mark, NdCall)
      else
        going = false
      end
    end

primitive _Call
  """
  ponyc's `call`: the argument list of a call.

  Only `(` and never its newline form: a parenthesis that begins a line
  begins a statement.
  """
  fun apply(p: Parser ref) =>
    p.start(NdArgs)
    p.bump()
    if not (p.at(TkRparen) or p.at(TkWhere)) then
      _Positional(p)
    end
    if p.at(TkWhere) then
      _NamedArgs(p)
    end
    p.expect(TkRparen, "a closing parenthesis")
    p.finish()
    if p.at(TkQuestion) then
      p.bump()
    end

primitive _Positional
  fun apply(p: Parser ref) =>
    _RawSeq(p)
    while p.at(TkComma) do
      p.bump()
      _RawSeq(p)
    end

primitive _NamedArgs
  """
  ponyc's `named`: the `where name = value` arguments of a call.
  """
  fun apply(p: Parser ref) =>
    p.start(NdNamedArgs)
    p.bump()
    _NamedArg(p)
    while p.at(TkComma) do
      p.bump()
      _NamedArg(p)
    end
    p.finish()

primitive _NamedArg
  fun apply(p: Parser ref) =>
    p.start(NdNamedArg)
    p.expect(TkId, "an argument name")
    p.expect(TkAssign, "an equals sign")
    _RawSeq(p)
    p.finish()

primitive _ConstExpr
  """
  ponyc's `const_expr`: a `#` and the expression it makes constant.
  """
  fun apply(p: Parser ref) =>
    p.start(NdConstExpr)
    p.bump()
    _Postfix(p, _ExprNormal)
    p.finish()
