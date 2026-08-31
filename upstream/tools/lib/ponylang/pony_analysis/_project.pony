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
  names a C function. ponyc's scheme table (`use.c`) has six rows:
  `package:` -- the default when none is written, and the only one a
  Pony name resolves through -- plus `lib:`, `path:`, `cincludedir:`,
  `cdefine:`, and `test:`, which exists for ponyc's own tests.
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
              package = StringLiteralValue(recover val tree.text(child)? end)
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

primitive _Scheme
  """
  What a `use` locator names, if it names a Pony package.

  `None` for the schemes that name no package -- the link and C-shim
  directives -- and for an unknown scheme, which is ponyc's error to
  report: reading it as a package name would invent a dependency, so it
  is dropped here too.
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

primitive _OpensScope
  """
  Whether a node bounds the visibility of the names declared inside it.

  ponyc marks these with `SCOPE()` in its grammar, but the list there does
  not transfer: `for`, `with`, `object` and lambdas get their scopes from
  the desugaring, and this tree is not desugared. So the ones the
  desugaring would have produced are named here instead.

  `NdUseFFI` is on ponyc's list and is easy to miss, because an FFI
  declaration does not look like a scope. It has to be one: the standard
  library declares thirty `use @pony_asio_event_*` in one file, each with a
  parameter named `event`, and without a scope each one they would all be
  visible over the whole file and collide.
  """
  fun apply(kind: SyntaxKind): Bool =>
    match kind
    | NdModule | NdClassDef | NdObject | NdMethod
    | NdSeq | NdFor | NdWith | NdCase
    | NdLambda | NdBareLambda
    | NdUseFFI => true
    else
      false
    end

primitive _BodyStart
  """
  Where the names a scope binds become visible.

  Not the same as where the scope starts. A method's type parameters are
  visible in its own signature, but its parameters are not visible until the
  body -- `fun f[A](x: A)` reads `A` from the signature, while a `for` name
  must not capture the iterator expression that produces it, as in
  `for x in x.next()`.

  So this is where the body begins: after `=>` for a method or a lambda,
  after `do` for a `for` or a `with`. For everything else it is the start of
  the scope itself.
  """
  fun apply(tree: SyntaxTree val, offsets: Array[USize] val, element: USize)
    : (USize | None)
  =>
    let opener =
      match try tree.kind(element)? else return None end
      | NdMethod | NdLambda | NdBareLambda => TkDblarrow
      | NdFor | NdWith => TkDo
      else
        return None
      end

    try
      for child in tree.children(element)? do
        if tree.kind(child)? is opener then
          return offsets(child)? + tree.width(child)?
        end
      end
    end
    None

primitive _BoundName
  """
  The name a binding node binds, which is its first identifier.

  Every one of them is shaped that way -- `let x`, `x: U32`, `A: Any val`,
  `x = expr` -- so one rule finds all of them.
  """
  fun apply(tree: SyntaxTree val, element: USize): (USize | None) =>
    try
      for child in tree.children(element)? do
        if tree.kind(child)? is TkId then
          return child
        end
      end
    end
    None

primitive _Bindings
  """
  Every name bound inside one document, with the source it is visible over.

  One walk, carrying a stack of open scopes. A binding belongs to the
  innermost scope enclosing it, and no binding node is itself a scope, so
  the top of the stack is always the right one.
  """
  fun apply(
    tree: SyntaxTree val,
    index: LineIndex,
    offsets: Array[USize] val,
    source: String val)
    : Array[Binding] val
  =>
    recover val
      let out = Array[Binding]
      let emit = _Emitter(tree, index, offsets, out)

      // depth, where the scope starts, where its bindings become visible,
      // and where it ends.
      let scopes = Array[(USize, USize, USize, USize)]

      for (element, depth, at, kind, width) in tree.walk() do
        while
          try scopes(scopes.size() - 1)?._1 >= depth else false end
        do
          try scopes.pop()? end
        end

        if _OpensScope(kind) then
          let body =
            match _BodyStart(tree, offsets, element)
            | let starts: USize => starts
            else
              at
            end
          scopes.push((depth, at, body, at + width))
        end

        (let scope_from, let body_from, let scope_to) =
          try
            (let _, let s, let b, let e) = scopes(scopes.size() - 1)?
            (s, b, e)
          else
            continue
          end

        match kind
        | NdLocal =>
          // Visible from where it is written. Pony rejects a use before
          // the declaration, so starting the scope earlier would resolve a
          // name the compiler will not.
          emit.one(element, BindLocal, at, scope_to)
        | NdParam | NdLambdaParam | NdLambdaCapture =>
          emit.one(element, BindParam, body_from, scope_to)
        | NdField =>
          emit.one(element, BindField, scope_from, scope_to)
        | NdTypeParam =>
          emit.one(element, BindTypeParam, scope_from, scope_to)
        | NdIdSeq =>
          emit.all(element, BindLocal, body_from, scope_to)
        end
      end

      out
    end

class _Emitter
  """
  Collects bindings while the walk runs.

  A class rather than a pair of functions because every call would
  otherwise carry the same four things through: the tree, the index, the
  offsets and the list being built.
  """
  let _tree: SyntaxTree val
  let _index: LineIndex
  let _offsets: Array[USize] val
  let _out: Array[Binding]

  new create(
    tree: SyntaxTree val,
    index: LineIndex,
    offsets: Array[USize] val,
    out: Array[Binding])
  =>
    _tree = tree
    _index = index
    _offsets = offsets
    _out = out

  fun ref one(
    element: USize,
    kind: BindingKind,
    from: USize,
    to: USize)
  =>
    """
    The name a binding node binds.
    """
    match _BoundName(_tree, element)
    | let named: USize => _push(element, named, kind, from, to)
    end

  fun ref all(
    element: USize,
    kind: BindingKind,
    from: USize,
    to: USize)
  =>
    """
    Every identifier under a node, each bound in its own right.

    A `for` or a `with` binds one name or a tuple of them, and a tuple
    nests.
    """
    try
      let span = _tree.subtree_size(element)?
      var i = element
      while i < (element + span) do
        if _tree.kind(i)? is TkId then
          // A name in an id sequence is its own whole declaration: there
          // is no type and no initialiser to include.
          _push(i, i, kind, from, to)
        end
        i = i + 1
      end
    end

  fun ref _push(
    element: USize,
    named: USize,
    kind: BindingKind,
    from: USize,
    to: USize)
  =>
    try
      let at = _offsets(named)?
      let width = _tree.width(named)?
      let whole = _offsets(element)?
      _out.push(
        Binding(
          recover val _tree.text(named)? end,
          kind,
          Span.from_bytes(_index, whole, whole + _tree.width(element)?),
          Span.from_bytes(_index, at, at + width),
          Span.from_bytes(_index, from, to),
          from,
          to,
          at,
          at + width))
    end

primitive _IdentifierAt
  """
  The identifier covering a byte offset, if the innermost thing there is
  one.
  """
  fun apply(
    tree: SyntaxTree val,
    index: LineIndex,
    offsets: Array[USize] val,
    byte: USize)
    : (Identifier | None)
  =>
    let path = tree.path_to(byte)
    try
      let leaf = path(path.size() - 1)?
      if not (tree.kind(leaf)? is TkId) then
        return None
      end
      let at = offsets(leaf)?
      let width = tree.width(leaf)?
      Identifier(
        recover val tree.text(leaf)? end,
        Span.from_bytes(index, at, at + width),
        at,
        _Qualifier(tree, path, leaf))
    else
      None
    end

primitive _Qualifier
  """
  The package alias a type name is written behind, as in `col.List`.

  Only inside a type. A dot anywhere else is a field access or a method
  call on an expression, and its left side is a value rather than a
  package.
  """
  fun apply(tree: SyntaxTree val, path: Array[USize] val, leaf: USize)
    : String val
  =>
    let parent = try path(path.size() - 2)? else return "" end
    if not (try tree.kind(parent)? is NdNominal else false end) then
      return ""
    end
    try
      var previous: (USize | None) = None
      for child in tree.children(parent)? do
        if child == leaf then
          match previous
          | let before: USize =>
            return recover val tree.text(before)? end
          end
          return ""
        end
        if tree.kind(child)? is TkId then
          previous = child
        end
      end
    end
    ""
