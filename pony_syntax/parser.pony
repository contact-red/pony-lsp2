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
    """Index into the token stream, of the next unconsumed token."""
  var _offset: USize = 0
    """Byte offset of `_index`."""

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

  fun ref _flush_trivia() =>
    """
    Emit whitespace and comments up to the next significant token, into
    whatever node is currently open.
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
    Open a node. Pending trivia go to the enclosing node first, so that a
    node begins at its first real token and the trivia between two items
    belong to what contains them.

    Unless nothing is open: the root has nothing to be enclosed by, so
    leading whitespace or a leading comment belongs inside it. Flushing
    there would put them before the root and leave the tree with two.
    """
    if _open.size() > 0 then
      _flush_trivia()
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
      _elems(index)? = (k, (_offset - from).u32(),
        (_elems.size() - index).u32())
    end

  fun ref bump() =>
    """
    Emit the next significant token, and any trivia before it.
    """
    _flush_trivia()
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

  fun ref expected(what: String val) =>
    """
    Record that `what` was expected here. Consumes nothing.
    """
    (let found, _, let byte) = _peek(_index)
    _diagnostics.push(SyntaxDiagnostic(byte, 0,
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
    _flush_trivia()
    while _open.size() > 0 do
      finish()
    end
    let elems: Array[(SyntaxKind, U32, U32)] val =
      _elems = recover Array[(SyntaxKind, U32, U32)] end
    let diags: Array[SyntaxDiagnostic val] val =
      _diagnostics = recover Array[SyntaxDiagnostic val] end
    SyntaxTree(_source, elems, diags)
