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
              recover val
                source.substring(from.isize(),
                  (from + (try tree.width(n)? else 0 end)).isize())
              end
            else
              ""
            end
          let name_span =
            match name_element
            | let n: USize =>
              let from = try offsets(n)? else 0 end
              Span.from_bytes(index, from,
                from + (try tree.width(n)? else 0 end))
            else
              Span.from_bytes(index, at, at)
            end

          let container =
            try open(open.size() - 1)?._2 else None end

          out.push(Declaration(k, name,
            Span.from_bytes(index, at, at + width), name_span, container))
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
        let fold_kind =
          match kind
          | NdClassDef | NdMethod | NdBody | NdMembers | NdParams =>
            FoldRegion
          | TkNestedComment => FoldComment
          | TkString => FoldComment
          else
            continue
          end

        (let start_line, _) = index.position(at)
        (let raw_finish, let finish_character) = index.position(at + width)

        // A span that ends at the first character of a line covers the
        // newline before it and nothing else on that line, so the last
        // line worth hiding is the one before.
        let finish_line =
          if (finish_character == 0) and (raw_finish > start_line) then
            raw_finish - 1
          else
            raw_finish
          end

        if finish_line > start_line then
          out.push(FoldingRegion(fold_kind, start_line, finish_line))
        end
      end

      out
    end
