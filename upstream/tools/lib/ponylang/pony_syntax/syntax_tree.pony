class val SyntaxTree
  """
  A source and the tree that covers it, flattened into one pre-order array.

  Each element carries its kind, its width in bytes, and the size of its
  subtree in elements. The children of element `i` begin at `i + 1`, and the
  next sibling of `i` is at `i + subtree_size(i)`. A leaf has a subtree size
  of one.

  Elements carry widths and not offsets, so an edit changes only the elements
  that contain it. An offset is derived by adding the widths of the leaves
  that precede an element, which `offset` does.

  Lossless: the leaves tile the source in order, so `reprint` reproduces it.
  """
  let source: String val
  let diagnostics: Array[SyntaxDiagnostic val] val
  let _elems: Array[(SyntaxKind, U32, U32)] val
    """
    Kind, width in bytes, subtree size in elements.

    Not `embed`, which would save an allocation, because an embedded array
    must be built in place and this one is built by the parser and handed
    over. One allocation per tree rather than per element, so the difference
    is not worth contorting the construction for.
    """

  new val create(
    source': String val,
    elems: Array[(SyntaxKind, U32, U32)] val,
    diagnostics': Array[SyntaxDiagnostic val] val)
  =>
    source = source'
    _elems = elems
    diagnostics = diagnostics'

  fun size(): USize =>
    """
    The number of elements, leaves and interior nodes together.
    """
    _elems.size()

  fun kind(i: USize): SyntaxKind ? =>
    _elems(i)?._1

  fun width(i: USize): USize ? =>
    """
    How many bytes of source element `i` covers.
    """
    _elems(i)?._2.usize()

  fun subtree_size(i: USize): USize ? =>
    """
    How many elements element `i` spans, itself included. One, for a leaf.
    """
    _elems(i)?._3.usize()

  fun is_leaf(i: USize): Bool ? =>
    _elems(i)?._3 == 1

  fun offset(i: USize): USize ? =>
    """
    The byte offset of element `i`.

    Leaves tile the source in pre-order, so this is the total width of the
    leaves before `i`. Linear in `i`; a walk that needs every offset should
    use `walk`, which accumulates them.
    """
    if i >= _elems.size() then error end
    var total: USize = 0
    var j: USize = 0
    while j < i do
      (_, let w, let s) = _elems(j)?
      if s == 1 then total = total + w.usize() end
      j = j + 1
    end
    total

  fun text(i: USize): String iso^ ? =>
    """
    The exact source text element `i` covers.
    """
    let from = offset(i)?
    source.substring(from.isize(), (from + width(i)?).isize())

  fun children(i: USize): ChildIterator ? =>
    """
    The indices of the direct children of element `i`.
    """
    ChildIterator(this, i, subtree_size(i)?)

  fun path_to(byte: USize): Array[USize] val =>
    """
    The elements containing byte offset `byte`, outermost first, ending at
    the innermost that covers it.

    This is what expanding a selection walks: each step outwards is the
    next span. Empty when the offset is past the end of the source.
    """
    recover val
      let path = Array[USize]
      let root_width = try width(0)? else 0 end

      if (size() > 0) and (byte < root_width) then
        path.push(0)
        var index: USize = 0
        var from: USize = 0
        var span = try subtree_size(0)? else 1 end
        var descended = true

        while descended do
          descended = false
          var child = index + 1
          var at = from
          while child < (index + span) do
            let child_width = try width(child)? else 0 end
            let child_span = try subtree_size(child)? else 1 end
            if (byte >= at) and (byte < (at + child_width)) then
              path.push(child)
              index = child
              from = at
              span = child_span
              descended = true
              break
            end
            at = at + child_width
            child = child + child_span
          end
        end
      end

      path
    end

  fun walk(): TreeWalk^ =>
    """
    Every element in pre-order as `(index, depth, offset, kind, width)`,
    with offsets accumulated as the walk proceeds.
    """
    TreeWalk._create(this)

  fun reprint(): String iso^ =>
    """
    Concatenate the leaves. Equal to `source` for any tree this package
    builds, which is what "lossless" means and what the tests assert.
    """
    let out = recover String(source.size()) end
    var offset': USize = 0
    for (_, w, s) in _elems.values() do
      if s == 1 then
        let width' = w.usize()
        out.append(source, offset', width')
        offset' = offset' + width'
      end
    end
    consume out

class ChildIterator is Iterator[USize]
  """
  The indices of the direct children of one element.
  """
  let _tree: SyntaxTree box
  let _limit: USize
  var _next: USize

  new create(tree: SyntaxTree box, parent: USize, span: USize) =>
    _tree = tree
    _next = parent + 1
    _limit = parent + span

  fun has_next(): Bool =>
    _next < _limit

  fun ref next(): USize ? =>
    let current = _next
    _next = _next + _tree.subtree_size(current)?
    current

class TreeWalk is Iterator[(USize, USize, USize, SyntaxKind, USize)]
  """
  A pre-order walk yielding `(index, depth, offset, kind, width)`.

  Depth and offset are both accumulated, so a full walk costs one pass
  rather than one `offset` call per element.
  """
  let _tree: SyntaxTree box
  var _index: USize = 0
  var _offset: USize = 0
  embed _ends: Array[USize] = Array[USize]

  new _create(tree: SyntaxTree box) =>
    _tree = tree

  fun has_next(): Bool =>
    _index < _tree.size()

  fun ref next(): (USize, USize, USize, SyntaxKind, USize) ? =>
    // Leave any subtrees this element is past.
    while
      try _ends(_ends.size() - 1)? <= _index else false end
    do
      _ends.pop()?
    end

    let i = _index
    let depth = _ends.size()
    let k = _tree.kind(i)?
    let w = _tree.width(i)?
    let span = _tree.subtree_size(i)?
    let at = _offset

    if span == 1 then
      _offset = _offset + w
    else
      _ends.push(i + span)
    end

    _index = _index + 1
    (i, depth, at, k, w)
