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
    foldable = _Foldable(_tree, _index, _offsets)
    diagnostics =
      recover val
        let out = Array[Diagnostic](_tree.diagnostics.size())
        for d in _tree.diagnostics.values() do
          out.push(Diagnostic(
            Span.from_bytes(_index, d.offset, d.offset + d.width),
            d.message))
        end
        out
      end

  fun span_of(element: USize): Span =>
    """
    The span of one tree element.
    """
    let from = try _offsets(element)? else 0 end
    Span.from_bytes(_index, from,
      from + (try _tree.width(element)? else 0 end))

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
      var i = path.size()
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
      spans
    end
