primitive Skeleton
  """
  Take an expression or a method body as a balanced region rather than
  parsing it.

  A placeholder for the expression rules. The extent is right, which is what
  folding, selection and an outline need; what is inside is a flat run of
  tokens and nested blocks.

  Balance matters for more than tidiness: a method body may contain an
  `object` literal with `fun` members, and stopping at the first `fun` would
  end the body in the middle of one. So the scan tracks the regions Pony
  closes with `end` and the bracket pairs, and only tests the stop set at
  depth zero.
  """
  fun apply(p: Parser ref, stop: Array[TokenKind] box) =>
    p.start(NdBody)
    var depth: USize = 0
    while not p.eof() do
      let c = p.current()
      if (depth == 0) and _in(c, stop) then
        break
      end
      if _in(c, TokenSets.bracket_open()) or
        _in(c, TokenSets.block_open())
      then
        depth = depth + 1
      elseif _in(c, TokenSets.closers()) then
        if depth == 0 then
          // A closer we did not open belongs to whatever encloses this.
          break
        end
        depth = depth - 1
      end
      p.bump()
    end
    p.finish()

  fun _in(c: TokenKind, kinds: Array[TokenKind] box): Bool =>
    for k in kinds.values() do
      if c is k then return true end
    end
    false
