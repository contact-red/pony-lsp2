primitive FoldRegion
  """
  A declaration, a body, or another structural region.
  """
  fun name(): String val => "region"

primitive FoldComment
  """
  A comment or a docstring spanning more than one line.
  """
  fun name(): String val => "comment"

type FoldKind is (FoldRegion | FoldComment)

class val FoldingRegion
  """
  Lines that can be collapsed to the first of them.

  Inclusive of both ends, and only ever produced when there is more than
  one line, because a region that hides nothing is noise in a gutter.
  """
  let kind: FoldKind
  let start_line: USize
  let finish_line: USize

  new val create(kind': FoldKind, start_line': USize, finish_line': USize) =>
    kind = kind'
    start_line = start_line'
    finish_line = finish_line'
