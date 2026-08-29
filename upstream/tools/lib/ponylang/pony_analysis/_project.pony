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
        // Declarations and the constructs inside a body that a keyword
        // opens and an `end` or a brace closes. Not the member list, whose
        // extent is the entity's own but for the signature line, and not a
        // docstring: a fold that hides what a thing is for is a fold
        // nobody wants.
        let fold_kind =
          match kind
          | NdClassDef | NdMethod
          | NdIf | NdIfDef | NdIfTypeSet
          | NdWhile | NdRepeat | NdFor | NdWith
          | NdTry | NdMatch | NdRecover | NdObject
          | NdLambda | NdBareLambda => FoldRegion
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

primitive _Uses
  """
  Project the `use` declarations out of a tree.

  Only the ones that name a Pony package. An `NdUse` holding an `NdUseFFI`
  names a C function; a `lib:` locator names a native library to link and a
  `path:` one adds a search path. ponyc has exactly these schemes, and
  `package:` -- the default when none is written -- is the only one a Pony
  name resolves through.
  """
  fun apply(
    tree: SyntaxTree val,
    index: LineIndex,
    offsets: Array[USize] val,
    source: String val)
    : Array[UseDecl] val
  =>
    recover val
      let out = Array[UseDecl]

      for (element, _, at, kind, width) in tree.walk() do
        if not (kind is NdUse) then
          continue
        end

        var alias = ""
        var package = ""
        var ffi = false

        try
          for child in tree.children(element)? do
            let child_kind = tree.kind(child)?
            if child_kind is NdUseFFI then
              ffi = true
              break
            elseif child_kind is NdUseName then
              for named in tree.children(child)? do
                if tree.kind(named)? is TkId then
                  alias = recover val tree.text(named)? end
                end
              end
            elseif child_kind is TkString then
              package = _Unquote(recover val tree.text(child)? end)
            end
          end
        end

        if (not ffi) and (package.size() > 0) then
          match _Scheme(package)
          | let located: String val =>
            out.push(
              UseDecl(located, alias, Span.from_bytes(index, at, at + width)))
          end
        end
      end

      out
    end

primitive _Unquote
  """
  The text of a string literal, without its quotes.

  A `use` path admits no escapes, so taking the bytes between the quotes is
  the whole of it.
  """
  fun apply(literal: String val): String val =>
    let quoted = try literal(0)? == '"' else false end
    if (literal.size() >= 2) and quoted then
      literal.substring(1, literal.size().isize() - 1)
    else
      literal
    end

primitive _Scheme
  """
  What a `use` locator names, if it names a Pony package.

  `None` for the schemes that do not: `lib:` links a native library and
  `path:` adds a search path. An unknown scheme is ponyc's error to report,
  and reading it as a package name would invent a dependency, so it is
  dropped here too.
  """
  fun apply(locator: String val): (String val | None) =>
    let colon =
      try
        locator.find(":")?
      else
        return locator
      end
    let scheme = locator.substring(0, colon)
    if scheme == "package" then
      locator.substring(colon + 1)
    else
      None
    end
