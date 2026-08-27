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
    _run(p, stop, false)
    p.finish()

  fun _run(p: Parser ref, stop: Array[TokenKind] box, nested: Bool) =>
    """
    Consume tokens, opening a node for each balanced region.

    The stop set is tested only outside any region, so a method body does
    not end at a `fun` that belongs to an `object` literal. A closer that
    was not opened here belongs to whatever encloses this, so it ends the
    run rather than being consumed.
    """
    while not p.eof() do
      let c = p.current()

      if (not nested) and _in(c, stop) then
        return
      end
      if _in(c, TokenSets.closers()) then
        return
      end

      // A brace opens a lambda or an object literal, which reads as a
      // block even though `}` closes it rather than `end`. A parenthesis
      // or a square bracket does not: the arguments of a call spread over
      // three lines are not a block.
      let opens_block =
        _in(c, TokenSets.block_open()) or (c is TkLbrace) or
          (c is TkAtLbrace)
      if opens_block or _in(c, TokenSets.bracket_open()) then
        p.start(if opens_block then NdBlock else NdGroup end)
        p.bump()
        _run(p, stop, true)
        if _in(p.current(), TokenSets.closers()) then
          p.bump()
        end
        p.finish()
      else
        p.bump()
      end
    end

  fun _in(c: TokenKind, kinds: Array[TokenKind] box): Bool =>
    for k in kinds.values() do
      if c is k then return true end
    end
    false
