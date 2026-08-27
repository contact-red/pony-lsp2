primitive Parse
  """
  Parse a source into a tree.

  The grammar here is a fraction of Pony's: enough to exercise the runtime
  end to end and to give the item extents that an outline and folding need,
  and no more. The remaining rules are ported against the same `Parser`,
  which is why they need nothing from this file.
  """
  fun apply(source: String val): SyntaxTree val =>
    let p = Parser(source)
    _Module(p)
    p.build()

primitive _TopLevel
  """
  The tokens a top-level item can start with.

  This is ponyc's `RESTART` set for `use` and `class_def`, and it is what
  bounds the cost of a syntax error: an item that does not parse costs that
  item, because the next one starts at one of these.
  """
  fun apply(): Array[TokenKind] val =>
    [ TkUse; TkType; TkInterface; TkTrait
      TkPrimitive; TkStruct; TkClass; TkActor ]

primitive _Module
  """
  ponyc's `module` rule: an optional package docstring, then use commands
  and type definitions, to the end of the source.
  """
  fun apply(p: Parser ref) =>
    p.start(NdModule)

    if p.at(TkString) then
      p.bump()
    end

    while not p.eof() do
      if p.at(TkUse) then
        _Use(p)
      elseif p.at_any(_TopLevel()) then
        _Item(p)
      else
        p.error_and_recover(
          "a use command or a type definition", _TopLevel())
      end
    end

    // ponyc's `module` ends with SKIP(TK_EOF). Emitting it matters here for
    // a second reason: `bump` flushes pending trivia first, so this is what
    // puts a trailing newline inside the module rather than after it.
    p.bump()
    p.finish()

primitive _Use
  """
  ponyc's `use` rule, without the `if` condition, which needs the
  expression grammar.
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
    else
      p.error_and_recover(
        "a package path or an FFI declaration", _TopLevel())
    end

    p.finish()

primitive _Item
  """
  A top-level declaration, taken as far as the next one.

  A placeholder for the entity rules. It gets the extent right, which is
  what an outline and folding want first, and the rules that replace it
  need change nothing above this point.
  """
  fun apply(p: Parser ref) =>
    p.start(NdItem)
    p.bump()
    while not (p.eof() or p.at_any(_TopLevel())) do
      p.bump()
    end
    p.finish()
