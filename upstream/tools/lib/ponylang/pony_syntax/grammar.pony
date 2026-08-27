// Pony's item grammar, ported rule for rule from ponyc's parser.c: module,
// use, entity declarations, members, methods, fields and parameters.
//
// Method bodies, field values, default arguments and use conditions are
// expressions, and `expr_grammar.pony` has those rules.

primitive Parse
  """
  Parse a source into a tree.

  Never fails, whatever the input. What cannot be interpreted becomes an
  `NdError` node bounded by the next item, and parsing continues.
  """
  fun apply(source: String val): SyntaxTree val =>
    let p = Parser(source)
    _Module(p)
    p.build()

primitive _Module
  """
  ponyc's `module`: an optional package docstring, then use commands and
  entity declarations, to the end of the source.
  """
  fun apply(p: Parser ref) =>
    p.start(NdModule)

    if p.at(TkString) then
      p.bump()
    end

    while not p.eof() do
      if p.at(TkUse) then
        _Use(p)
      elseif p.at_any(TokenSets.entities()) then
        _ClassDef(p)
      else
        p.error_and_recover(
          "a use command or a type definition", TokenSets.top_level())
      end
    end

    // ponyc's module ends with SKIP(TK_EOF). Emitting it matters here for a
    // second reason: `bump` flushes pending trivia first, so this is what
    // puts a trailing newline inside the module rather than after it.
    p.bump()
    p.finish()

primitive _Use
  """
  ponyc's `use`: `use [name =] (uri | ffi) [if condition]`.
  """
  fun apply(p: Parser ref) =>
    p.start(NdUse)
    p.bump()

    if p.at(TkId) and (p.nth(1) is TkAssign) then
      p.start(NdUseName)
      p.bump()
      p.bump()
      p.finish()
    end

    if p.at(TkString) then
      p.bump()
    elseif p.at(TkAt) then
      _UseFFI(p)
    else
      p.error_and_recover(
        "a package path or an FFI declaration", TokenSets.top_level())
    end

    if p.at(TkIf) then
      p.bump()
      _Infix(p, _ExprNormal)
    end

    p.finish()

primitive _UseFFI
  """
  ponyc's `use_ffi`: `@name[ReturnType](params) [?]`.
  """
  fun apply(p: Parser ref) =>
    p.start(NdUseFFI)
    p.bump()
    p.expect_any([TkId; TkString], "an FFI name")
    if p.at(TkLsquare) then
      _TypeArgs(p)
    else
      p.expected("a return type")
    end
    p.expect_any(TokenSets.lparen(), "an opening parenthesis")
    if not p.at(TkRparen) then
      _Params(p)
    end
    p.expect(TkRparen, "a closing parenthesis")
    if p.at(TkQuestion) then
      p.bump()
    end
    p.finish()

primitive _ClassDef
  """
  ponyc's `class_def`: an entity keyword, then its name, type parameters,
  provides list, docstring and members.
  """
  fun apply(p: Parser ref) =>
    p.start(NdClassDef)
    p.bump()

    if p.at(TkBackslash) then
      _Annotations(p)
    end
    if p.at(TkAt) then
      p.bump()
    end
    if p.at_any(TokenSets.caps()) then
      p.bump()
    end

    p.expect(TkId, "a name")

    if p.at_any(TokenSets.lsquare()) then
      _TypeParams(p)
    end

    if p.at(TkIs) then
      p.start(NdProvides)
      p.bump()
      _TypeRule(p)
      p.finish()
    end

    if p.at(TkString) then
      p.bump()
    end

    // Only when there is something to put in it. A node opened before
    // anything is consumed takes the trivia that precede it, which would
    // put the blank line after a member-less entity inside it and make its
    // fold range a line too long.
    if not (p.eof() or p.at_any(TokenSets.top_level())) then
      _Members(p)
    end

    p.finish()

primitive _Annotations
  """
  ponyc's `annotations`: `\\name[, name]*\\`.
  """
  fun apply(p: Parser ref) =>
    p.start(NdAnnotations)
    p.bump()
    p.expect(TkId, "an annotation")
    while p.at(TkComma) do
      p.bump()
      p.expect(TkId, "an annotation")
    end
    p.expect(TkBackslash, "a closing backslash")
    p.finish()

primitive _Members
  """
  The fields and methods of an entity, to the start of the next item.

  ponyc requires every field to precede every method and rejects a source
  where one does not. This accepts them in any order and leaves the
  ordering rule to whatever checks the tree: a language server is asked
  about sources that are wrong, and refusing to describe them is the
  behaviour being replaced.
  """
  fun apply(p: Parser ref) =>
    p.start(NdMembers)
    while not (p.eof() or p.at(TkEnd) or p.at_any(TokenSets.top_level())) do
      if p.at_any(TokenSets.field_start()) then
        _Field(p)
      elseif p.at_any(TokenSets.method_start()) then
        _Method(p)
      else
        p.error_and_recover(
          "a field or a method", TokenSets.member_or_top_level())
      end
    end
    p.finish()

primitive _Field
  """
  ponyc's `field`: `(var | let | embed) name: Type [= value] [docstring]`.
  """
  fun apply(p: Parser ref) =>
    p.start(NdField)
    p.bump()
    p.expect(TkId, "a field name")
    p.expect(TkColon, "a type declaration, which a field must have")
    _TypeRule(p)
    if p.at(TkAssign) then
      p.bump()
      _Infix(p, _ExprNormal)
    end
    if p.at(TkString) then
      p.bump()
    end
    p.finish()

primitive _Method
  """
  ponyc's `method`: `(fun | be | new) [cap] name [typeparams](params)
  [: Type] [?] [docstring] [=> body]`.
  """
  fun apply(p: Parser ref) =>
    p.start(NdMethod)
    p.bump()

    if p.at(TkBackslash) then
      _Annotations(p)
    end
    if p.at_any(TokenSets.caps()) or p.at(TkAt) then
      p.bump()
    end

    p.expect(TkId, "a method name")

    if p.at_any(TokenSets.lsquare()) then
      _TypeParams(p)
    end

    p.expect_any(TokenSets.lparen(), "an opening parenthesis")
    if not p.at(TkRparen) then
      _Params(p)
    end
    p.expect(TkRparen, "a closing parenthesis")

    if p.at(TkColon) then
      p.bump()
      _TypeRule(p)
    end
    if p.at(TkQuestion) then
      p.bump()
    end
    if p.at(TkString) then
      p.bump()
    end
    if p.at(TkDblarrow) then
      p.bump()
      _RawSeq(p)
    end

    p.finish()

primitive _Params
  """
  ponyc's `params`: `param[, param]*`, where a param may be `...`.
  """
  fun apply(p: Parser ref) =>
    p.start(NdParams)
    _Param(p)
    while p.at(TkComma) do
      p.bump()
      _Param(p)
    end
    p.finish()

primitive _Param
  """
  ponyc's `param`: `name: Type [= default]`, or an ellipsis.
  """
  fun apply(p: Parser ref) =>
    if p.at(TkEllipsis) then
      p.bump()
      return
    end

    p.start(NdParam)
    p.expect(TkId, "a parameter name")
    p.expect(TkColon, "a type declaration, which a parameter must have")
    _TypeRule(p)
    if p.at(TkAssign) then
      _DefaultArg(p)
    end
    p.finish()
