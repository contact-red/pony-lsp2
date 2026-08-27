use "../pony_syntax"

primitive _Declarations
  """
  Project the declarations out of a tree in one walk.
  """
  fun apply(
    tree: SyntaxTree val,
    index: LineIndex,
    offsets: Array[USize] val,
    source: String val)
    : Array[Declaration] val
  =>
    recover val
      let out = Array[Declaration]
      // Open declarations, as (tree depth, index into `out`), so that a
      // member knows which entity encloses it.
      let open = Array[(USize, USize)]

      for (element, depth, at, kind, width) in tree.walk() do
        while
          try open(open.size() - 1)?._1 >= depth else false end
        do
          try open.pop()? end
        end

        match _Kind(tree, element, kind)
        | let k: DeclarationKind =>
          let name_element = _NameOf(tree, element)
          let name =
            match name_element
            | let n: USize =>
              let from = try offsets(n)? else 0 end
              let to = from + (try tree.width(n)? else 0 end)
              recover val source.substring(from.isize(), to.isize()) end
            else
              ""
            end
          let name_span =
            match name_element
            | let n: USize =>
              let from = try offsets(n)? else 0 end
              Span.from_bytes(
                index,
                from,
                from + (try tree.width(n)? else 0 end))
            else
              Span.from_bytes(index, at, at)
            end

          let container =
            try open(open.size() - 1)?._2 else None end

          out.push(
            Declaration(
              k,
              name,
              Span.from_bytes(index, at, at + width),
              name_span,
              container))
          open.push((depth, out.size() - 1))
        end
      end

      out
    end

primitive _Kind
  """
  The declaration a node declares, or `None` if it declares nothing.

  Read from the node's first leaf child rather than from the node kind,
  because one node kind covers every entity: `NdClassDef` is a class or an
  actor or a primitive, and the keyword is what says which.
  """
  fun apply(tree: SyntaxTree val, element: USize, kind: SyntaxKind)
    : (DeclarationKind | None)
  =>
    let keyword =
      match kind
      | NdClassDef | NdMethod | NdField => _FirstLeaf(tree, element)
      else
        return None
      end

    match keyword
    | TkType => DeclTypeAlias
    | TkInterface => DeclInterface
    | TkTrait => DeclTrait
    | TkPrimitive => DeclPrimitive
    | TkStruct => DeclStruct
    | TkClass => DeclClass
    | TkActor => DeclActor
    | TkVar | TkLet | TkEmbed => DeclField
    | TkFun => DeclFunction
    | TkBe => DeclBehaviour
    | TkNew => DeclConstructor
    else
      None
    end

primitive _FirstLeaf
  """
  The kind of the first leaf under an element.
  """
  fun apply(tree: SyntaxTree val, element: USize): (SyntaxKind | None) =>
    try
      for child in tree.children(element)? do
        if tree.is_leaf(child)? then
          return tree.kind(child)?
        end
      end
    end
    None

primitive _NameOf
  """
  The element holding a declaration's name: its first direct child that is
  an identifier.

  Direct, so that an annotation's names are not mistaken for it -- those
  are inside an `NdAnnotations` node rather than beside the keyword.
  """
  fun apply(tree: SyntaxTree val, element: USize): (USize | None) =>
    try
      for child in tree.children(element)? do
        if tree.is_leaf(child)? and (tree.kind(child)? is TkId) then
          return child
        end
      end
    end
    None

primitive _Foldable
  """
  The regions a client can collapse.
  """
  fun apply(
    tree: SyntaxTree val,
    index: LineIndex,
    offsets: Array[USize] val)
    : Array[FoldingRegion] val
  =>
    recover val
      let out = Array[FoldingRegion]

      for (element, _, at, kind, width) in tree.walk() do
        // Declarations and the balanced regions inside a body. Not the
        // member list, whose extent is the entity's own but for the
        // signature line, and not a docstring: a fold that hides what a
        // thing is for is a fold nobody wants.
        let fold_kind =
          match kind
          | NdClassDef | NdMethod | NdBlock => FoldRegion
          else
            continue
          end

        (let start_line, _) = index.position(at)

        // A region ends at its last line of content, not at the line that
        // closes it. Hiding the `end` of a block leaves the structure
        // unreadable, and a client shows the closing line as the marker
        // for what was collapsed.
        let finish_line = _LastContentLine(tree, index, offsets, element)

        if finish_line > start_line then
          out.push(FoldingRegion(fold_kind, start_line, finish_line))
        end
      end

      out
    end

primitive _LastContentLine
  """
  The line a region's fold should end on.

  The last line of content, where a region's own closing line is not
  content: hiding it leaves the structure unreadable, and a client shows
  that line as the marker for what was collapsed. `end` and `}` close a
  region that way; `)` and `]` sit at the end of the thing they close --
  the last line of a parenthesised type is the line with the `)` on it.

  Only its own. A closer belonging to a block nested inside this one is
  the last thing in this one, which is why a `while` wrapping an `if`
  folds to the `if`'s `end` and not past it.
  """
  fun apply(
    tree: SyntaxTree val,
    index: LineIndex,
    offsets: Array[USize] val,
    element: USize)
    : USize
  =>
    let span = try tree.subtree_size(element)? else 1 end
    var i = element + span
    var skipped_own_end = false

    while i > element do
      i = i - 1
      try
        if not tree.is_leaf(i)? then
          continue
        end
        let kind = tree.kind(i)?
        if _Trivia(kind) then
          continue
        end
        if (not skipped_own_end) and
          ((kind is TkEnd) or (kind is TkRbrace))
        then
          skipped_own_end = true
          continue
        end
        (let line, _) = index.position(offsets(i)? + tree.width(i)?)
        return line
      end
    end

    (let line, _) = index.position(try offsets(element)? else 0 end)
    line

primitive _Trivia
  fun apply(kind: SyntaxKind): Bool =>
    match kind
    | TkWhitespace | TkLineComment | TkNestedComment | TkEof => true
    else
      false
    end

primitive _Selectable
  """
  Whether a leaf is worth offering as a step when expanding a selection.

  A token whose text its kind fixes -- a keyword, a bracket, an operator
  -- is not: someone expanding from the cursor on `primitive` wants the
  declaration, not the word. One whose text it does not fix is: an
  identifier or a literal is the thing a person reaches for first.
  """
  fun apply(kind: SyntaxKind): Bool =>
    match kind
    | TkId | TkString | TkInt | TkFloat => true
    else
      false
    end
