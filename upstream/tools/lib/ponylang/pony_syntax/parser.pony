primitive _MaxNesting
  """
  The deepest grammar recursion the parser will enter.

  The grammar recurses on the machine stack, a few frames per descent.
  What is counted is the recursion, not source nesting: the common
  expression shapes descend twice per source level, so parentheses meet
  the limit at about half this number. Refusing here keeps the refusal
  a diagnostic instead of a crash.
  """
  fun apply(): USize => 2500

class Parser
  """
  A cursor over the significant tokens of a source, and a builder for the
  tree that covers all of them, trivia included.

  No method on this class fails. Where the grammar expects something that is
  not there, `error_and_recover` records a diagnostic, wraps what it skipped
  in an `NdError` node, and parsing continues from a point the caller names.
  That is the whole difference from ponyc's parser, which returns no tree at
  all once an error has been reported.

  Trivia never reach the grammar. `start` flushes any pending whitespace and
  comments into the enclosing node before opening a new one, so trivia
  between two items belong to what contains them rather than to whichever
  item happens to follow.
  """
  let _source: String val
  let _stream: TokenStream val
  var _elems: Array[(SyntaxKind, U32, U32)] iso =
    recover Array[(SyntaxKind, U32, U32)] end
    """
    Isolated rather than embedded so that `build` can hand it over with a
    destructive read instead of copying it. Every element is sendable -- a
    union of primitives and two integers -- so the array is still built with
    ordinary pushes.
    """
  var _diagnostics: Array[SyntaxDiagnostic val] iso =
    recover Array[SyntaxDiagnostic val] end
  embed _open: Array[(USize, USize)] = Array[(USize, USize)]
  var _index: USize = 0
    """
    Index into the token stream, of the next unconsumed token.
    """
  var _offset: USize = 0
    """
    Byte offset of `_index`.
    """
  var _depth: USize = 0
    """
    Grammar recursion depth, counted by `descend`/`ascend`. Counted
    explicitly because the open-node stack cannot measure it: most
    rules wrap retroactively from a checkpoint and open nothing while
    they descend, and the machine stack grows regardless.
    """

  new create(source': String val) =>
    _source = source'
    _stream = recover val TokenStream(source') end

  fun tag _is_trivia(k: TokenKind): Bool =>
    match k
    | TkWhitespace | TkLineComment | TkNestedComment => true
    else
      false
    end

  fun _peek(from: USize): (TokenKind, USize, USize) =>
    """
    The next significant token at or after `from`: its kind, its index, and
    the byte offset it starts at. `TkEof` when there is none.
    """
    var i = from
    var byte = _offset
    var j = _index
    // Walk forward from the cursor, accumulating width.
    while j < i do
      try byte = byte + _stream(j)?._2.usize() end
      j = j + 1
    end
    while i < _stream.size() do
      try
        (let k, let w) = _stream(i)?
        if not _is_trivia(k) then return (k, i, byte) end
        byte = byte + w.usize()
      end
      i = i + 1
    end
    (TkEof, _stream.size(), byte)

  fun ref descend(): Bool =>
    """
    Enter one level of grammar recursion. Returns whether the limit is
    now exceeded.
    """
    _depth = _depth + 1
    _depth > _MaxNesting()

  fun ref too_deep(what: String val): Bool =>
    """
    Enter one level of grammar recursion; at the limit, refuse the
    region with a diagnostic naming `what`, resynchronise to the
    nearest closing token, and leave the depth balanced. Returns
    whether it refused, and a guarded rule returns without parsing
    further when it did — its other exits still `ascend`.
    """
    if descend() then
      error_and_recover(
        "a less deeply nested " + what + " (grammar depth limit " +
          _MaxNesting().string() + ")",
        TokenSets.nesting_close())
      ascend()
      true
    else
      false
    end

  fun ref ascend() =>
    """
    Leave the level `descend` entered. Every `descend` is paired with one
    `ascend`, on the refusal path too.
    """
    _depth = _depth - 1

  fun current(): TokenKind =>
    """
    The kind of the next significant token, without consuming anything.
    """
    _peek(_index)._1

  fun nth(n: USize): TokenKind =>
    """
    The kind of the significant token `n` places ahead, `nth(0)` being
    `current`.
    """
    var i = _index
    var seen: USize = 0
    while true do
      (let k, let index', _) = _peek(i)
      if seen == n then return k end
      if k is TkEof then return TkEof end
      seen = seen + 1
      i = index' + 1
    end
    TkEof

  fun at(k: TokenKind): Bool =>
    current() is k

  fun at_any(kinds: Array[TokenKind] box): Bool =>
    let c = current()
    for k in kinds.values() do
      if c is k then return true end
    end
    false

  fun eof(): Bool =>
    current() is TkEof

  fun ref _emit(k: SyntaxKind, w: USize) =>
    _elems.push((k, w.u32(), 1))
    _offset = _offset + w

  fun ref flush_trivia() =>
    """
    Emit the whitespace and comments before the next significant token,
    into whatever node is open now.

    A rule that parses a sequence calls this between elements, so that what
    separates them belongs to the sequence rather than to either side.
    """
    while _index < _stream.size() do
      try
        (let k, let w) = _stream(_index)?
        if not _is_trivia(k) then return end
        _emit(k, w.usize())
        _index = _index + 1
      else
        return
      end
    end

  fun ref start(k: NodeKind) =>
    """
    Open a node. Pending trivia go to the enclosing node first, so a node
    begins at its first real token: `is Bar` and not ` is Bar`, and a
    declaration whose fold range would otherwise start on the blank line
    above it.

    Two things follow from that, and both are the caller's to respect. A
    node opened before nothing is consumed takes the trivia anyway, so a
    rule must not open one speculatively -- which is why an entity with no
    members has no member list rather than an empty one. And the root has
    nothing to be enclosed by, so leading trivia belongs inside it;
    flushing there would put elements before the root and leave the tree
    with two.
    """
    if _open.size() > 0 then
      flush_trivia()
    end
    _open.push((_elems.size(), _offset))
    _elems.push((k, 0, 0))

  fun ref finish() =>
    """
    Close the innermost open node, filling in the width and subtree size it
    turned out to have.
    """
    try
      (let index, let from) = _open.pop()?
      (let k, _, _) = _elems(index)?
      _elems(index)? =
        (k, (_offset - from).u32(), (_elems.size() - index).u32())
    end

  fun pos(): USize =>
    """
    How far the parser has read.

    Two reads with the same value mean the rule between them consumed
    nothing, which a loop must not go around again.
    """
    _index

  fun ref checkpoint(): (USize, USize) =>
    """
    Where a node would begin if one were opened now: the element index and
    the byte offset. Give it to `wrap_from` to put a node around everything
    parsed since.

    Flushes pending trivia first, as `start` does. Trivia belongs to the
    node being built, not to the one that may later be wrapped around this
    point: without the flush an infix operand begins at the space before
    it, and every extent taken from it is a character wide of the mark.
    """
    flush_trivia()
    (_elems.size(), _offset)

  fun ref wrap_from(mark: (USize, USize), k: NodeKind) =>
    """
    Put a node of kind `k` around every element added since `mark`.

    An infix construct is not known to be one until its operator appears --
    `A` is a type and `A | B` is a union -- and a source-ordered tree cannot
    rebuild itself around the operator the way ponyc's `INFIX_BUILD` does.
    So a rule parses its left side, and wraps only if an operator follows.

    Safe against the open stack because every open node was opened before
    the mark, so inserting at it shifts none of their indices.
    """
    (let index, let from) = mark
    try
      _elems.insert(
        index,
        (k, (_offset - from).u32(), ((_elems.size() - index) + 1).u32()))?
    end

  fun ref bump() =>
    """
    Emit the next significant token, and any trivia before it.
    """
    flush_trivia()
    if _index < _stream.size() then
      try
        (let k, let w) = _stream(_index)?
        _emit(k, w.usize())
        _index = _index + 1
      end
    end

  fun ref expect(k: TokenKind, what: String val): Bool =>
    """
    Emit the next significant token if it is `k`. Otherwise record that
    `what` was expected and emit nothing, leaving the cursor where it is so
    that the caller can decide how to recover.
    """
    if at(k) then
      bump()
      true
    else
      expected(what)
      false
    end

  fun ref expect_any(kinds: Array[TokenKind] box, what: String val): Bool =>
    """
    Emit the next significant token if it is any of `kinds`.
    """
    if at_any(kinds) then
      bump()
      true
    else
      expected(what)
      false
    end

  fun ref expected(what: String val) =>
    """
    Record that `what` was expected here. Consumes nothing.
    """
    (let found, _, let byte) = _peek(_index)
    _diagnostics.push(
      SyntaxDiagnostic(
        byte,
        0,
        "expected " + what + ", found " + found.name()))

  fun ref error_and_recover(what: String val, resync: Array[TokenKind] box) =>
    """
    Wrap everything up to the next token in `resync` in an `NdError` node.

    This is ponyc's `RESTART`, which names the tokens a rule can resume at.
    ponyc uses it to keep reporting further errors; here it also bounds what
    an error costs, so that one bad item does not take the rest of the file
    with it.
    """
    expected(what)
    if eof() then
      return
    end
    start(NdError)
    // Always consume at least one token, or a rule whose recovery set
    // contains the current token would spin.
    bump()
    while not (eof() or at_any(resync)) do
      bump()
    end
    finish()

  fun ref build(): SyntaxTree val =>
    """
    Close anything still open, account for the trailing trivia, and hand
    back the tree.
    """
    flush_trivia()
    while _open.size() > 0 do
      finish()
    end
    let elems: Array[(SyntaxKind, U32, U32)] val =
      _elems = recover Array[(SyntaxKind, U32, U32)] end
    let diags: Array[SyntaxDiagnostic val] val =
      _diagnostics = recover Array[SyntaxDiagnostic val] end
    SyntaxTree(_source, elems, diags)
