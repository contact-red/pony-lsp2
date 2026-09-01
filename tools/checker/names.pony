use "collections"
use "../../upstream/tools/lib/ponylang/pony_analysis"
use "../../upstream/tools/lib/ponylang/pony_syntax"

class val _PackageImports
  """
  How one package's `use` declarations resolved: the aliased ones by
  alias, the bare package ones in written order, both as canonical
  directories. The loader resolves them; name resolution reads them
  here to search the packages ponyc would.
  """
  let aliases: Map[String, String val] val
    """Alias to canonical directory."""
  let opens: Array[String val] val
    """Unaliased `use` targets, then builtin, in search order."""

  new val create(
    aliases': Map[String, String val] val,
    opens': Array[String val] val)
  =>
    aliases = aliases'
    opens = opens'

class val _EntityInfo
  """
  One entity's member names, and the names in its provides list,
  which member lookups follow.
  """
  let members: Array[String val] val
  let provides: Array[String val] val

  new val create(
    members': Array[String val] val,
    provides': Array[String val] val)
  =>
    members = members'
    provides = provides'

primitive _ProjectEntities
  """
  The entities a package's files declare, each with its member names
  and provides list — what cross-package name resolution needs of a
  package it imports.
  """
  fun apply(files: Array[FileData] val): Map[String, _EntityInfo] val =>
    """
    The table for one package's files.
    """
    recover val
      let out = Map[String, _EntityInfo]
      for file in files.values() do
        let tree = file.tree
        let at = file.facts.offsets()
        try
          for child in tree.children(0)? do
            if tree.kind(child)? is NdClassDef then
              (let name, let info) = _entity_info(tree, at, child)
              if name.size() > 0 then
                out(name) = info
              end
            end
          end
        end
      end
      out
    end

  fun _entity_info(
    tree: SyntaxTree val,
    at: Array[USize] val,
    entity: USize)
    : (String val, _EntityInfo)
  =>
    var name: String val = ""
    var keyword: SyntaxKind = TkTrait
    var wrote_constructor = false
    let members = Array[String val]
    let provides = Array[String val]
    try
      for child in tree.children(entity)? do
        match tree.kind(child)?
        | TkClass | TkActor | TkPrimitive | TkStruct | TkTrait
        | TkInterface | TkType =>
          keyword = tree.kind(child)?
        | TkId =>
          if name.size() == 0 then
            name = _text(tree, at, child)
          end
        | NdProvides =>
          provides_names(tree, at, child, provides)
        | NdMembers =>
          member_names(tree, at, child, members)
          wrote_constructor = _has_constructor(tree, child)
        end
      end
    end
    // The members ponyc synthesizes before its name passes: `create`
    // on a concrete entity with no written constructor, `eq`/`ne` on
    // a primitive, and `runtime_override_defaults` on `Main`.
    match keyword
    | TkClass | TkActor | TkPrimitive | TkStruct =>
      if not wrote_constructor then
        members.push("create")
      end
    end
    if keyword is TkPrimitive then
      members.push("eq")
      members.push("ne")
    end
    if (keyword is TkActor) and (name == "Main") then
      members.push("runtime_override_defaults")
    end
    (name, _EntityInfo(_freeze(members), _freeze(provides)))

  fun _has_constructor(tree: SyntaxTree val, members: USize): Bool =>
    try
      for member in tree.children(members)? do
        if tree.kind(member)? is NdMethod then
          for part in tree.children(member)? do
            match tree.kind(part)?
            | TkNew => return true
            | TkFun | TkBe => break
            end
          end
        end
      end
    end
    false

  fun _freeze(names: Array[String val] box): Array[String val] val =>
    let out = recover iso Array[String val](names.size()) end
    for n in names.values() do
      out.push(n)
    end
    consume out

  fun member_names(
    tree: SyntaxTree val,
    at: Array[USize] val,
    members: USize,
    out: Array[String val] ref)
  =>
    """
    The field and method names a members block declares, appended to
    `out`.
    """
    try
      for member in tree.children(members)? do
        match tree.kind(member)?
        | NdField | NdMethod =>
          for part in tree.children(member)? do
            if tree.kind(part)? is TkId then
              out.push(_text(tree, at, part))
              break
            end
          end
        end
      end
    end

  fun provides_names(
    tree: SyntaxTree val,
    at: Array[USize] val,
    element: USize,
    out: Array[String val] ref)
  =>
    """
    The nominal names a provides clause reaches, however grouped. A
    qualified name keeps its qualifier, joined with a dot: the dotted
    form matches no entity table key, so a lookup through it fails
    open instead of resolving against a same-named local entity.
    """
    try
      for child in tree.children(element)? do
        match tree.kind(child)?
        | NdNominal =>
          var name: String val = ""
          for part in tree.children(child)? do
            if tree.kind(part)? is TkId then
              name =
                if name.size() == 0 then
                  _text(tree, at, part)
                else
                  name + "." + _text(tree, at, part)
                end
            end
          end
          if name.size() > 0 then
            out.push(name)
          end
        | NdInfixType | NdGroupedType =>
          provides_names(tree, at, child, out)
        end
      end
    end

  fun _text(
    tree: SyntaxTree val,
    at: Array[USize] val,
    element: USize)
    : String val
  =>
    let from = try at(element)? else _Unreachable(); 0 end
    let w = try tree.width(element)? else _Unreachable(); 0 end
    tree.source.substring(from.isize(), (from + w).isize())

class _Namespace
  """
  Everything a name in one file can resolve against: the file's own
  scope-aware bindings, the members of its enclosing entities and
  object literals, and the entities of its package, its imports, and
  builtin — with the provides chains member lookups follow. Lookups
  fail open: a name no lookup can prove unresolvable is accepted, so
  a gap in what is searched costs a missed rejection. A wrong answer
  is a bug, not a gap.
  """
  let _file: FileData
  let _imports: _PackageImports
  let _entities: Map[String, Map[String, _EntityInfo] val] box
    """Entity tables by canonical directory, the loader's cache."""
  let _own: String val

  new create(
    file: FileData,
    own: String val,
    imports: _PackageImports,
    entities: Map[String, Map[String, _EntityInfo] val] box)
  =>
    _file = file
    _own = own
    _imports = imports
    _entities = entities

  fun binding_covers(name: String val, offset: USize): Bool =>
    for candidate in _file.facts.bindings.values() do
      if (candidate.name == name) and candidate.covers(offset) then
        return true
      end
    end
    false

  fun binding_anywhere(name: String val): Bool =>
    for candidate in _file.facts.bindings.values() do
      if candidate.name == name then
        return true
      end
    end
    false

  fun is_alias(name: String val): Bool =>
    _imports.aliases.contains(name)

  fun type_name(name: String val): Bool =>
    """
    Whether a bare type name resolves: own package, then each open
    import, then builtin. ponyc merges all of these into one symbol
    table per module and rejects a clash, so any search order finds
    the same single answer. An import can only supply what its
    package exports.
    """
    try
      if _entities(_own)?.contains(name) then
        return true
      end
    end
    if _importable(name) then
      for dir in _imports.opens.values() do
        try
          if _entities(dir)?.contains(name) then
            return true
          end
        end
      end
    end
    false

  fun _importable(name: String val): Bool =>
    """
    Whether an import can supply `name`: ponyc's import pass refuses
    private names and `Main`.
    """
    (try name(0)? != '_' else false end) and (name != "Main")

  fun qualified_type(alias: String val, name: String val)
    : (Bool | None)
  =>
    """
    Whether `alias.name` resolves. `None` when the alias itself is
    unknown — a package error, not a definition error.
    """
    try
      let dir = _imports.aliases(alias)?
      try
        _entities(dir)?.contains(name)
      else
        // A known alias whose package has no entity table cannot be
        // proved to lack the name.
        true
      end
    else
      None
    end

  fun member(enclosing: Array[String val] box, name: String val): Bool =>
    """
    Whether `name` is a member of any enclosing entity, provides
    chains included. The enclosing names resolve in this file's
    namespace, where they are written; every later chain link
    resolves in the package of the entity that wrote it, then in
    builtin, whose names cannot be shadowed — never in this file's
    namespace, where a same-named entity would be the wrong one. A
    link no table carries ends the lookup as found: nothing past it
    can be proved absent.
    """
    let seen = Set[String]
    // Each pending lookup: the directory whose package wrote the
    // name, or "" for the enclosing names written in this file.
    let queue = Array[(String val, String val)]
    for e in enclosing.values() do
      queue.push(("", e))
    end
    var i: USize = 0
    while i < queue.size() do
      (let ctx, let entity) = try queue(i)? else _Unreachable(); break end
      i = i + 1
      let key: String val = ctx + "\t" + entity
      if seen.contains(key) then
        continue
      end
      seen.set(key)
      let found =
        if ctx.size() == 0 then
          _entity_in_scope(entity)
        else
          _entity_in(ctx, entity)
        end
      match found
      | (let dir: String val, let info: _EntityInfo) =>
        for m in info.members.values() do
          if m == name then
            return true
          end
        end
        for p in info.provides.values() do
          queue.push((dir, p))
        end
      | None =>
        return true
      end
    end
    false

  fun _entity_in_scope(name: String val)
    : ((String val, _EntityInfo) | None)
  =>
    """
    An entity as this file's namespace resolves it, with the
    directory of the package that declares it.
    """
    try
      return (_own, _entities(_own)?(name)?)
    end
    if _importable(name) then
      for dir in _imports.opens.values() do
        try
          return (dir, _entities(dir)?(name)?)
        end
      end
    end
    None

  fun _entity_in(ctx: String val, name: String val)
    : ((String val, _EntityInfo) | None)
  =>
    """
    An entity as the package at `ctx` resolves a bare name it wrote:
    its own table, then builtin for a public name.
    """
    try
      return (ctx, _entities(ctx)?(name)?)
    end
    if _importable(name) then
      try
        let builtin = _imports.opens(_imports.opens.size() - 1)?
        return (builtin, _entities(builtin)?(name)?)
      end
    end
    None

  fun suggest(
    name: String val,
    offset: USize,
    enclosing: Array[String val] box)
    : (String val | None)
  =>
    """
    ponyc's alternate-name suggestion: the same name with its leading
    underscore toggled, else one differing only by case.
    """
    let toggled: String val =
      if try name(0)? == '_' else false end then
        let t: String val = name.substring(1)
        t
      else
        let t: String val = "_" + name
        t
      end
    if binding_covers(toggled, offset) or type_name(toggled) or
      member(enclosing, toggled)
    then
      return toggled
    end
    // ponyc's case search folds a name to the type or value side it
    // is written on, so a value-shaped name can only suggest values
    // and a type-shaped one only types — type parameters included.
    // Pony forbids two names differing only by case in one scope, so
    // the first match is the only match.
    if _type_shaped(name) then
      for candidate in _file.facts.bindings.values() do
        if (candidate.kind is BindTypeParam) and
          _case_match(candidate.name, name) and candidate.covers(offset)
        then
          return candidate.name
        end
      end
      match _case_entity(_own, name)
      | let n: String val => return n
      end
      for dir in _imports.opens.values() do
        match _case_entity(dir, name)
        | let n: String val => return n
        end
      end
      return None
    end
    for candidate in _file.facts.bindings.values() do
      if (candidate.kind isnt BindTypeParam) and
        _case_match(candidate.name, name) and candidate.covers(offset)
      then
        return candidate.name
      end
    end
    None

  fun _type_shaped(name: String val): Bool =>
    var i: USize = 0
    while try name(i)? == '_' else false end do
      i = i + 1
    end
    let c = try name(i)? else return false end
    (c >= 'A') and (c <= 'Z')

  fun _case_match(candidate: String val, written: String val): Bool =>
    """
    The same name up to ASCII case, and not the written name itself.
    """
    if (candidate == written) or (candidate.size() != written.size())
    then
      return false
    end
    var i: USize = 0
    while i < candidate.size() do
      let a = try candidate(i)? else _Unreachable(); return false end
      let b = try written(i)? else _Unreachable(); return false end
      if _lower(a) != _lower(b) then
        return false
      end
      i = i + 1
    end
    true

  fun _lower(c: U8): U8 =>
    if (c >= 'A') and (c <= 'Z') then c + 0x20 else c end

  fun _case_entity(dir: String val, written: String val)
    : (String val | None)
  =>
    try
      for (n, _) in _entities(dir)?.pairs() do
        if ((dir == _own) or _importable(n)) and _case_match(n, written)
        then
          return n
        end
      end
    end
    None

primitive CheckNames
  """
  ponyc's unresolved-name rules over one file: a bare reference must
  reach a binding, a member of an enclosing entity or object literal,
  an entity, or a `use` alias; `this.name` must reach a member; a
  nominal type must reach an entity or a type parameter. Wordings are
  ponyc's — `can't find declaration` for references, with its
  alternate-name suggestion, and `can't find definition` for types.
  Lookups fail open, as `_Namespace` states.
  """
  fun apply(
    file: FileData,
    own: String val,
    imports: _PackageImports,
    entities: Map[String, Map[String, _EntityInfo] val] box)
    : Array[CheckDiagnostic] val
  =>
    let out = Array[CheckDiagnostic]
    let ns = _Namespace(file, own, imports, entities)
    let tree = file.tree
    let at = file.facts.offsets()
    let stack = Array[(USize, SyntaxKind)]
    // Build-flag regions: an ifdef condition or a use guard holds
    // flags, not names.
    let skip = _flag_regions(tree)
    var skip_i: USize = 0

    for (element, depth, _, kind, _) in tree.walk() do
      stack.truncate(depth)
      while
        try skip(skip_i)?._2 <= element else false end
      do
        skip_i = skip_i + 1
      end
      let skipped =
        try
          (let from, let to) = skip(skip_i)?
          (element >= from) and (element < to)
        else
          false
        end
      if not skipped then
        match kind
        | NdRef =>
          _reference(ns, tree, at, element, stack, out, file.path)
        | NdDot =>
          _this_dot(ns, tree, at, element, stack, out, file.path)
        | NdNominal =>
          _nominal(ns, tree, at, element, stack, out, file.path)
        end
      end
      stack.push((element, kind))
    end
    let frozen = recover iso Array[CheckDiagnostic](out.size()) end
    for d in out.values() do
      frozen.push(d)
    end
    consume frozen

  fun _flag_regions(tree: SyntaxTree val): Array[(USize, USize)] =>
    """
    The element ranges of every ifdef condition and use guard,
    ascending by start element — the regions where an identifier is a
    build flag.
    """
    let out = Array[(USize, USize)]
    for (element, _, _, kind, _) in tree.walk() do
      try
        match kind
        | NdIfDef =>
          var in_condition = false
          for child in tree.children(element)? do
            match tree.kind(child)?
            | TkIfdef | TkElseif => in_condition = true
            | TkThen => in_condition = false
            | TkWhitespace | TkLineComment | TkNestedComment => None
            | NdAnnotations => None
            else
              if in_condition then
                out.push((child, child + tree.subtree_size(child)?))
                in_condition = false
              end
            end
          end
        | NdUse =>
          var in_guard = false
          for child in tree.children(element)? do
            match tree.kind(child)?
            | TkIf => in_guard = true
            | TkWhitespace | TkLineComment | TkNestedComment => None
            else
              if in_guard then
                out.push((child, child + tree.subtree_size(child)?))
                in_guard = false
              end
            end
          end
        end
      end
    end
    // The walk can push regions out of order — a `use`'s guard is a
    // direct child pushed before the walk reaches an ifdef nested
    // deeper inside the same `use` — and the caller's forward
    // pointer needs them ascending by start.
    let sorted = Array[(USize, USize)](out.size())
    for r in out.values() do
      var k: USize = 0
      while
        (k < sorted.size()) and
        ((try sorted(k)?._1 else 0 end) <= r._1)
      do
        k = k + 1
      end
      try
        sorted.insert(k, r)?
      else
        _Unreachable()
      end
    end
    sorted

  fun _offset(at: Array[USize] val, element: USize): USize =>
    try at(element)? else _Unreachable(); 0 end

  fun _text(
    tree: SyntaxTree val,
    at: Array[USize] val,
    element: USize)
    : String val
  =>
    _ProjectEntities._text(tree, at, element)

  fun _enclosing(
    tree: SyntaxTree val,
    stack: Array[(USize, SyntaxKind)] box,
    at: Array[USize] val)
    : Array[String val]
  =>
    """
    What member lookups search from here: the name of each enclosing
    entity, and the provides names of each enclosing object literal —
    a literal's inherited members come through its provides list
    exactly as an entity's do.
    """
    let out = Array[String val]
    for (el, kind) in stack.values() do
      if kind is NdClassDef then
        try
          for child in tree.children(el)? do
            if tree.kind(child)? is TkId then
              out.push(_text(tree, at, child))
              break
            end
          end
        end
      elseif kind is NdObject then
        try
          for child in tree.children(el)? do
            if tree.kind(child)? is NdProvides then
              _ProjectEntities.provides_names(tree, at, child, out)
            end
          end
        end
      end
    end
    out

  fun _object_member(
    tree: SyntaxTree val,
    stack: Array[(USize, SyntaxKind)] box,
    at: Array[USize] val,
    name: String val)
    : Bool
  =>
    """
    Whether any enclosing object literal declares `name` directly, or
    ponyc synthesizes it there — an object literal cannot write a
    constructor, so its `create` is always synthesized.
    """
    for (el, kind) in stack.values() do
      if kind is NdObject then
        if name == "create" then
          return true
        end
        try
          for child in tree.children(el)? do
            if tree.kind(child)? is NdMembers then
              let names = Array[String val]
              _ProjectEntities.member_names(tree, at, child, names)
              for n in names.values() do
                if n == name then
                  return true
                end
              end
            end
          end
        end
      end
    end
    false

  fun _under_lambda(stack: Array[(USize, SyntaxKind)] box): Bool =>
    """
    Whether the walk is inside a lambda literal. A lambda desugars to
    an object literal whose members — its method and its captures —
    this walk does not build, so a failed lookup under a lambda frame
    is accepted rather than reported against the enclosing entity.
    """
    for (_, kind) in stack.values() do
      if (kind is NdLambda) or (kind is NdBareLambda) then
        return true
      end
    end
    false

  fun _reference(
    ns: _Namespace box,
    tree: SyntaxTree val,
    at: Array[USize] val,
    element: USize,
    stack: Array[(USize, SyntaxKind)] box,
    out: Array[CheckDiagnostic] ref,
    path: String val)
  =>
    try
      for child in tree.children(element)? do
        if tree.kind(child)? is TkId then
          _check_name(ns, tree, at, child, stack, out, path)
          return
        end
      end
    end

  fun _check_name(
    ns: _Namespace box,
    tree: SyntaxTree val,
    at: Array[USize] val,
    id: USize,
    stack: Array[(USize, SyntaxKind)] box,
    out: Array[CheckDiagnostic] ref,
    path: String val)
  =>
    let name = _text(tree, at, id)
    if name == "_" then
      return
    end
    let offset = _offset(at, id)
    if ns.binding_covers(name, offset) then
      return
    end
    if ns.binding_anywhere(name) then
      // A binding of this name exists out of scope. ponyc splits that
      // into appears-after-use and not-in-scope; proving which needs
      // scope comparison this projection does not carry, so it is
      // accepted rather than misreported.
      return
    end
    if _object_member(tree, stack, at, name) then
      return
    end
    let enclosing = _enclosing(tree, stack, at)
    if ns.member(enclosing, name) then
      return
    end
    if ns.type_name(name) then
      return
    end
    if _under_lambda(stack) then
      return
    end
    if ns.is_alias(name) then
      // ponyc's refer pass allows a package reference only as the
      // left side of a dot.
      if _under_dot(stack) then
        return
      end
      out.push(
        CheckDiagnostic(path, offset,
          "a package can only appear as a prefix to a type"))
      return
    end
    out.push(
      CheckDiagnostic(
        path, offset, _decl_message(ns, name, offset, enclosing)))

  fun _under_dot(stack: Array[(USize, SyntaxKind)] box): Bool =>
    try stack(stack.size() - 1)?._2 is NdDot else false end

  fun _decl_message(
    ns: _Namespace box,
    name: String val,
    offset: USize,
    enclosing: Array[String val] box)
    : String val
  =>
    """
    ponyc's unresolved-reference wording, with its alternate-name
    suggestion when one is found.
    """
    match ns.suggest(name, offset, enclosing)
    | let alt: String val =>
      "can't find declaration of '" + name + "', did you mean '" +
        alt + "'?"
    | None =>
      let m: String val = "can't find declaration of '" + name + "'"
      m
    end

  fun _this_dot(
    ns: _Namespace box,
    tree: SyntaxTree val,
    at: Array[USize] val,
    element: USize,
    stack: Array[(USize, SyntaxKind)] box,
    out: Array[CheckDiagnostic] ref,
    path: String val)
  =>
    """
    `this.name` must name a member — ponyc's `refer_this_dot` — and
    `alias.name` must name a type the package exports — ponyc's
    `refer_packageref_dot`.
    """
    try
      var this_left = false
      var alias_left: (String val | None) = None
      var dot: (USize | None) = None
      for child in tree.children(element)? do
        match tree.kind(child)?
        | NdThis => this_left = true
        | NdRef =>
          let left = _ref_name(tree, at, child)
          if ns.is_alias(left) and
            (not ns.binding_covers(left, _offset(at, child)))
          then
            alias_left = left
          end
        | TkDot => dot = child
        | TkWhitespace | TkLineComment | TkNestedComment => None
        | TkId =>
          match alias_left
          | let alias: String val =>
            _package_member(ns, tree, at, alias, child, dot, out, path)
            return
          end
          if this_left then
            let name = _text(tree, at, child)
            let enclosing = _enclosing(tree, stack, at)
            // ponyc's refer_this_dot resolves the name lexically, so
            // any covering binding passes it there; what it means is
            // rejected by a later pass this checker does not carry.
            if (not _object_member(tree, stack, at, name)) and
              (not ns.member(enclosing, name)) and
              (not ns.binding_covers(name, _offset(at, child))) and
              (not _under_lambda(stack))
            then
              // ponyc's dot node sits at its dot token.
              let where_at =
                match dot
                | let dt: USize => dt
                | None => child
                end
              out.push(
                CheckDiagnostic(path, _offset(at, where_at),
                  _decl_message(ns, name, _offset(at, child),
                    enclosing)))
            end
          end
          return
        else
          return
        end
      end
    end

  fun _ref_name(
    tree: SyntaxTree val,
    at: Array[USize] val,
    element: USize)
    : String val
  =>
    try
      for child in tree.children(element)? do
        if tree.kind(child)? is TkId then
          return _text(tree, at, child)
        end
      end
    end
    ""

  fun _package_member(
    ns: _Namespace box,
    tree: SyntaxTree val,
    at: Array[USize] val,
    alias: String val,
    id: USize,
    dot: (USize | None),
    out: Array[CheckDiagnostic] ref,
    path: String val)
  =>
    """
    ponyc's `refer_packageref_dot`: the name after a package alias
    must be a type the package holds — a private one is refused at
    the dot, a missing one at the name.
    """
    let written = _text(tree, at, id)
    match ns.qualified_type(alias, written)
    | false =>
      out.push(
        CheckDiagnostic(path, _offset(at, id),
          "can't find type '" + written + "' in package '" + alias +
            "'"))
    | true =>
      if try written(0)? == '_' else false end then
        let where_at =
          match dot
          | let dt: USize => dt
          | None => id
          end
        out.push(
          CheckDiagnostic(path, _offset(at, where_at),
            "can't access a private type from another package"))
      end
    | None =>
      _Unreachable()
    end

  fun _nominal(
    ns: _Namespace box,
    tree: SyntaxTree val,
    at: Array[USize] val,
    element: USize,
    stack: Array[(USize, SyntaxKind)] box,
    out: Array[CheckDiagnostic] ref,
    path: String val)
  =>
    var qualifier: (USize | None) = None
    var name: (USize | None) = None
    try
      for child in tree.children(element)? do
        if tree.kind(child)? is TkId then
          match name
          | None => name = child
          | let first: USize =>
            qualifier = first
            name = child
          end
        end
      end
    end
    let name_id =
      match name
      | let id: USize => id
      | None => return
      end
    let written = _text(tree, at, name_id)
    let offset = _offset(at, name_id)
    match qualifier
    | let q: USize =>
      // ponyc's order: the package, then the `_` rule, then the
      // definition, then the private check on what it found.
      let alias = _text(tree, at, q)
      if not ns.is_alias(alias) then
        out.push(
          CheckDiagnostic(path, _offset(at, q),
            "can't find package '" + alias + "'"))
        return
      end
      if written == "_" then
        out.push(
          CheckDiagnostic(path, _offset(at, q),
            "'_' cannot be in a package"))
        return
      end
      match ns.qualified_type(alias, written)
      | false =>
        out.push(
          CheckDiagnostic(path, offset, _def_message(written)))
      | None =>
        _Unreachable()
      | true =>
        if try written(0)? == '_' else false end then
          out.push(
            CheckDiagnostic(path, offset,
              "can't access a private type from another package"))
        end
      end
    | None =>
      if written == "_" then
        if not _as_tuple_dontcare(stack) then
          out.push(
            CheckDiagnostic(path, offset,
              "can't use '_' as a type name"))
        end
        return
      end
      if ns.binding_covers(written, offset) or ns.type_name(written) then
        return
      end
      out.push(CheckDiagnostic(path, offset, _def_message(written)))
    end

  fun _def_message(written: String val): String val =>
    """
    ponyc's unresolved-type wording.
    """
    "can't find definition of '" + written + "'"

  fun _as_tuple_dontcare(stack: Array[(USize, SyntaxKind)] box): Bool =>
    """
    Whether a `_` nominal sits where ponyc's `as` sugar turns it into
    a don't-care type: a direct element of the tuple type an `as`
    casts to. ponyc reads that shape after parentheses collapse, so
    any number of grouping parens may sit between the element and the
    tuple, and between the tuple and the `as`. Everywhere else a `_`
    nominal is an error.
    """
    var i = stack.size()
    while
      (i > 0) and
      (try stack(i - 1)?._2 is NdGroupedType else false end)
    do
      i = i - 1
    end
    if (i == 0) or
      (try stack(i - 1)?._2 isnt NdTupleType else true end)
    then
      return false
    end
    i = i - 1
    while
      (i > 0) and
      (try stack(i - 1)?._2 is NdGroupedType else false end)
    do
      i = i - 1
    end
    (i > 0) and (try stack(i - 1)?._2 is NdAsOp else false end)
