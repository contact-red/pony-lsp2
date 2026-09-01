use "../pony_syntax"

class val DocumentFacts
  """
  What is known about one document from its syntax alone.

  A pure function of the source: parse it, walk the tree once, and project
  what a language server asks for. Nothing here needs a compile, a
  workspace, or anything on disk, which is why it can answer about a buffer
  that has not been saved and does not compile.

  What syntax cannot decide is absent rather than guessed. There are no
  types here, and no resolved names.
  """
  let source: String val
  let declarations: Array[Declaration] val
  let uses: Array[UseDecl] val
  let bindings: Array[Binding] val
  let foldable: Array[FoldingRegion] val
  let diagnostics: Array[Diagnostic] val
  let _tree: SyntaxTree val
  let _index: LineIndex
  let _offsets: Array[USize] val
    """
    The byte offset of every element, so that nothing has to recompute one.
    """

  new val create(
    source': String val,
    encoding: PositionEncoding = Utf16)
  =>
    source = source'
    _tree = Parse(source')
    _index = LineIndex(source', encoding)

    _offsets =
      recover val
        let all = Array[USize](_tree.size())
        for (_, _, at, _, _) in _tree.walk() do
          all.push(at)
        end
        all
      end

    declarations = _Declarations(_tree, _index, _offsets, source')
    uses = _Uses(_tree, _index, _offsets, source')
    bindings = _Bindings(_tree, _index, _offsets, source')
    foldable = _Foldable(_tree, _index, _offsets)
    diagnostics =
      recover val
        let out = Array[Diagnostic](_tree.diagnostics.size())
        for d in _tree.diagnostics.values() do
          out.push(
            Diagnostic(
              Span.from_bytes(_index, d.offset, d.offset + d.width),
              d.message))
        end
        out
      end

  fun offsets(): Array[USize] val =>
    """
    The byte offset of every element, as `span_of` reads them. A
    consumer that walks the tree itself reads offsets here, computed
    once, instead of recomputing one per element.
    """
    _offsets

  fun tree(): SyntaxTree val =>
    """
    The parse these facts are projected from. A consumer that walks
    the tree itself takes it from here, so a file is parsed once.
    """
    _tree

  fun identifier_at(line: USize, character: USize): (Identifier | None) =>
    """
    The identifier written at a position, if one is.

    A cursor sitting just past the end of a name counts as being on it,
    because that is where a cursor ends up after typing one and it is where
    a double-click leaves it.
    """
    let byte = _index.offset(line, character)
    match _IdentifierAt(_tree, _index, _offsets, byte)
    | let found: Identifier => found
    else
      if byte > 0 then
        _IdentifierAt(_tree, _index, _offsets, byte - 1)
      else
        None
      end
    end

  fun binding_at(line: USize, character: USize): (Binding | None) =>
    """
    What the name at a position is bound to, within this document.

    `None` when the name is bound somewhere else -- another file, or
    another package -- which is the caller's cue to go and look. Syntax
    alone cannot tell those apart from a name that is bound nowhere.

    Where several bindings of one name are in scope, the innermost wins,
    which is the one visible over the least source.
    """
    match identifier_at(line, character)
    | let used: Identifier =>
      var best: (Binding | None) = None
      for candidate in bindings.values() do
        if (candidate.name == used.name) and candidate.covers(used.offset)
        then
          match best
          | let closest: Binding =>
            if candidate.extent() < closest.extent() then
              best = candidate
            end
          else
            best = candidate
          end
        end
      end
      best
    end

  fun span_of(element: USize): Span =>
    """
    The span of one tree element.
    """
    let from = try _offsets(element)? else 0 end
    let to = from + (try _tree.width(element)? else 0 end)
    Span.from_bytes(_index, from, to)

  fun enclosing(line: USize, character: USize): Array[Span] val =>
    """
    The spans containing a position, innermost first.

    What expanding a selection walks. Innermost first because that is the
    order a client applies them, and duplicates are dropped: a node with
    one child has the same span as that child, and offering the same
    selection twice makes the command look broken.
    """
    let byte = _index.offset(line, character)
    recover val
      let spans = Array[Span]
      let path = _tree.path_to(byte)

      // A position inside whitespace or a comment has nothing to select.
      // The innermost thing covering it is the run of trivia itself, and
      // offering that as the first step of an expanding selection is
      // offering to select the gap between two declarations. An empty
      // chain leaves the client to do whatever it does for plain text.
      let in_trivia =
        try
          _Trivia(_tree.kind(path(path.size() - 1)?)?)
        else
          true
        end

      // A leaf whose text is fixed by its kind -- a keyword, a piece of
      // punctuation -- is not a step worth offering: expanding from the
      // cursor on `primitive` should select the declaration, not the
      // word. An identifier or a literal is worth offering, because
      // selecting a name is what someone reaches for first.
      let drop_innermost =
        try
          let innermost = path(path.size() - 1)?
          _tree.is_leaf(innermost)? and
            (not _Selectable(_tree.kind(innermost)?))
        else
          false
        end

      if not in_trivia then
        var i = path.size() - if drop_innermost then 1 else 0 end
        while i > 0 do
          i = i - 1
          try
            let span = span_of(path(i)?)
            let duplicate =
              try
                let last = spans(spans.size() - 1)?
                (last.start_line == span.start_line) and
                  (last.start_character == span.start_character) and
                  (last.finish_line == span.finish_line) and
                  (last.finish_character == span.finish_character)
              else
                false
              end
            if not duplicate then
              spans.push(span)
            end
          end
        end
      end

      spans
    end
