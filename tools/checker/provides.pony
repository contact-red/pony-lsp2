use "collections"
use "../../upstream/tools/lib/ponylang/pony_syntax"

primitive CheckProvides
  """
  ponyc's `invalid provides type` rule: a provides clause may hold
  interfaces, traits, and intersections of those. A nominal that
  resolves to a class, actor, primitive or struct — or that names one
  of the entity's own type parameters — is an error, reported on the
  declaring entity (or on the `object` keyword of a literal) with an
  `invalid type here` Info at the offending nominal. A name the
  resolver cannot prove — an unresolvable link, a qualified name, or
  a type alias, whose right-hand structure the entity table does not
  hold — fails open. ponyc stops a clause at its first invalid
  nominal; the checker reports every one.

  The two shapes sit on different ponyc rungs: an entity's clause is
  the flatten pass — after unresolvable nominal types, before
  unresolved references; an object literal's is the expr pass, after
  both. `apply` returns them separately so the ladder can stage each
  where ponyc raises it.
  """
  fun apply(
    file: FileData,
    own: String val,
    imports: _PackageImports,
    entities: Map[String, Map[String, _EntityInfo] val] box)
    : (Array[CheckDiagnostic] val, Array[CheckDiagnostic] val)
  =>
    """
    The invalid-provides diagnostics for one file — entity clauses
    first, object-literal clauses second, since the ladder stages
    them on different rungs.
    """
    let entity_out = Array[CheckDiagnostic]
    let object_out = Array[CheckDiagnostic]
    let ns = _Namespace(file, own, imports, entities)
    let tree = file.tree
    let at = file.facts.offsets()
    for (element, _, _, kind, _) in tree.walk() do
      match kind
      | NdClassDef =>
        _entity_clause(ns, tree, at, element, entity_out, file.path)
      | NdObject =>
        _object_clause(ns, tree, at, element, object_out, file.path)
      end
    end
    (_FreezeDiags(entity_out), _FreezeDiags(object_out))

  fun _entity_clause(
    ns: _Namespace box,
    tree: SyntaxTree val,
    at: Array[USize] val,
    entity: USize,
    out: Array[CheckDiagnostic] ref,
    path: String val)
  =>
    var report_at: (USize | None) = None
    let type_params = Array[String val]
    try
      for child in tree.children(entity)? do
        match tree.kind(child)?
        | TkType =>
          // A type alias's `is` clause is its definition, not a
          // provides list.
          return
        | TkClass | TkActor | TkPrimitive | TkStruct | TkTrait
        | TkInterface =>
          if report_at is None then
            report_at = _offset(at, child)
          end
        | NdProvides =>
          match report_at
          | let kw: USize =>
            _clause(ns, tree, at, child, kw, type_params, out, path)
          | None =>
            // The grammar writes the keyword before the clause.
            _Unreachable()
          end
        | NdTypeParams =>
          _param_names(tree, at, child, type_params)
        end
      end
    end

  fun _object_clause(
    ns: _Namespace box,
    tree: SyntaxTree val,
    at: Array[USize] val,
    literal: USize,
    out: Array[CheckDiagnostic] ref,
    path: String val)
  =>
    """
    An object literal's provides clause takes the same rule, blamed
    on the `object` keyword. The literal has no type parameters of
    its own; a provides naming its enclosing entity's type parameter
    fails open — nothing here resolves it.
    """
    try
      let report_at = _offset(at, literal)
      for child in tree.children(literal)? do
        if tree.kind(child)? is NdProvides then
          _clause(ns, tree, at, child, report_at,
            Array[String val], out, path)
        end
      end
    end

  fun _clause(
    ns: _Namespace box,
    tree: SyntaxTree val,
    at: Array[USize] val,
    element: USize,
    report_at: USize,
    type_params: Array[String val] box,
    out: Array[CheckDiagnostic] ref,
    path: String val)
  =>
    try
      for child in tree.children(element)? do
        match tree.kind(child)?
        | NdNominal =>
          _nominal(ns, tree, at, child, report_at, type_params, out,
            path)
        | NdInfixType | NdGroupedType =>
          _clause(ns, tree, at, child, report_at, type_params, out,
            path)
        end
      end
    end

  fun _nominal(
    ns: _Namespace box,
    tree: SyntaxTree val,
    at: Array[USize] val,
    nominal: USize,
    report_at: USize,
    type_params: Array[String val] box,
    out: Array[CheckDiagnostic] ref,
    path: String val)
  =>
    var first: (USize | None) = None
    var second = false
    try
      for part in tree.children(nominal)? do
        if tree.kind(part)? is TkId then
          match first
          | None => first = part
          | let _: USize => second = true
          end
        end
      end
    end
    let id =
      match first
      | let f: USize => f
      | None => return
      end
    if second then
      // A qualified name: the alias's package structure is not in
      // the table, so it fails open.
      return
    end
    let written = _ProjectEntities._text(tree, at, id)
    for p in type_params.values() do
      if p == written then
        _report(out, path, report_at, _offset(at, id))
        return
      end
    end
    match ns.entity_keyword(written)
    | TkClass | TkActor | TkPrimitive | TkStruct =>
      _report(out, path, report_at, _offset(at, id))
    end

  fun _report(
    out: Array[CheckDiagnostic] ref,
    path: String val,
    report_at: USize,
    nominal_at: USize)
  =>
    out.push(
      CheckDiagnostic(path, report_at,
        CheckLegality.invalid_provides()
        where info' = CheckDiagnostic(path, nominal_at,
          "invalid type here")))

  fun _param_names(
    tree: SyntaxTree val,
    at: Array[USize] val,
    params: USize,
    out: Array[String val] ref)
  =>
    try
      for child in tree.children(params)? do
        if tree.kind(child)? is NdTypeParam then
          for part in tree.children(child)? do
            if tree.kind(part)? is TkId then
              out.push(_ProjectEntities._text(tree, at, part))
              break
            end
          end
        end
      end
    end

  fun _offset(at: Array[USize] val, element: USize): USize =>
    try at(element)? else _Unreachable(); 0 end
