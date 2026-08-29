use "collections"
use "../pony_analysis"
use "../pony_query"

class Binder is QueryRunner
  """
  What a workspace declares, and which declaration a name refers to.

  Holds the query engine and every table hanging off it. Mutable and
  unshared: this is the working state of whichever actor owns it.

  Files and their text arrive from outside through `set_source` and
  `set_files`. Nothing here touches a disk, which is what lets a test drive a
  whole workspace from string literals and what lets the language server
  answer about a buffer that was never saved.
  """
  embed _engine: Engine = _engine.create()
  embed _job: Map[QueryId, _Job] = _job.create()
  embed _source_id: Map[String, QueryId] = _source_id.create()
  embed _text: Map[String, String val] = _text.create()
  embed _files_id: Map[String, QueryId] = _files_id.create()
  embed _files: Map[String, Array[String val] val] = _files.create()
  embed _facts_id: Map[String, QueryId] = _facts_id.create()
  embed _facts: Map[String, DocumentFacts] = _facts.create()
  embed _declarations_id: Map[String, QueryId] = _declarations_id.create()
  embed _declarations: Map[String, Array[BoundItem] val] =
    _declarations.create()
  embed _imports_id: Map[String, QueryId] = _imports_id.create()
  embed _imports: Map[String, Array[Import] val] = _imports.create()
  embed _index_id: Map[String, QueryId] = _index_id.create()
  embed _index: Map[String, PackageIndex] = _index.create()
  embed _package_paths: Map[String, String val] = _package_paths.create()
  var _builtin: String val = ""

  fun revision(): Revision =>
    """
    The current version of the workspace.
    """
    _engine.revision()

  fun ref set_source(file: String val, text: String val) =>
    """
    The text of a file, saved or not.
    """
    _text(file) = text
    _engine.set_input(_source_query(file))

  fun ref set_files(package: String val, files: Array[String val] val) =>
    """
    Which files make up a package.

    A Pony package is a directory, so this is what a directory scan found.
    It is an input rather than something read here, because reading a
    directory is the caller's business and because a test needs a workspace
    that never existed on disk.
    """
    _files(package) = files
    _engine.set_input(_files_query(package))

  fun ref set_package_path(used: String val, package: String val) =>
    """
    Where a `use` path resolves to.

    `use "collections"` names a package by search path, and finding which
    directory that is means walking the search paths and the disk. That is
    the caller's, so the answer arrives here rather than being worked out
    here. A `use` path with no mapping is taken as naming its package
    directly, which is what makes a relative `use` inside one workspace
    work without any mapping at all.
    """
    _package_paths(used) = package

  fun ref set_builtin(package: String val) =>
    """
    Which package every file implicitly uses.

    Pony files do not write `use "builtin"`, so without this nothing
    resolves `U32` or `String`.
    """
    _builtin = package

  fun ref facts(file: String val): (DocumentFacts | None) =>
    """
    Everything syntax alone says about one file.
    """
    _engine.demand(_facts_query(file), this)
    try _facts(file)? else None end

  fun ref declarations(file: String val): Array[BoundItem] val =>
    """
    What one file declares.
    """
    _engine.demand(_declarations_query(file), this)
    try _declarations(file)? else recover val Array[BoundItem] end end

  fun ref imports(file: String val): Array[Import] val =>
    """
    What one file brings into scope with `use`.
    """
    _engine.demand(_imports_query(file), this)
    try _imports(file)? else recover val Array[Import] end end

  fun ref index(package: String val): PackageIndex =>
    """
    Everything a package declares.
    """
    _engine.demand(_index_query(package), this)
    try
      _index(package)?
    else
      PackageIndex(recover val Array[BoundItem] end)
    end

  fun ref resolve(file: String val, name: String val)
    : (BoundItem | None)
  =>
    """
    The declaration a type name written in `file` refers to.

    A plain function rather than a query: it is a map lookup, and
    `FINDINGS.md` says not to memoize what is cheaper to recompute. It still
    reads through `demand`, so called from inside a query the edges are
    recorded and called from outside they are not.

    Search order is the file's own package, then each unaliased `use`, then
    builtin -- which is the order ponyc resolves in, and the reason a
    package can shadow a builtin name.
    """
    let dot =
      try
        name.find(".")?
      else
        return _resolve_bare(file, name)
      end
    // Qualified: what is before the dot is a `use` alias.
    let qualifier: String val = name.substring(0, dot)
    let bare: String val = name.substring(dot + 1)
    for used in imports(file).values() do
      if (used.alias.size() > 0) and (used.alias == qualifier) then
        return index(package_for(used.package, file)).entity(bare)
      end
    end
    None

  fun ref _resolve_bare(file: String val, name: String val)
    : (BoundItem | None)
  =>
    match index(_package_of(file)).entity(name)
    | let found: BoundItem => return found
    end
    for used in imports(file).values() do
      if used.alias.size() == 0 then
        match index(package_for(used.package, file)).entity(name)
        | let found: BoundItem => return found
        end
      end
    end
    if _builtin.size() > 0 then
      return index(_builtin).entity(name)
    end
    None

  fun ref resolve_at(file: String val, line: USize, character: USize)
    : (Definition | None)
  =>
    """
    What the name at a position refers to.

    A binding inside the document wins, because a local shadows anything a
    package declares. Only when the document binds nothing under that name
    is the workspace asked.
    """
    let known =
      match facts(file)
      | let found: DocumentFacts => found
      else
        return None
      end

    match known.binding_at(line, character)
    | let bound: Binding => return bound
    end

    match known.identifier_at(line, character)
    | let used: Identifier => resolve(file, used.written())
    else
      None
    end

  fun ref declared_at(item: BoundItem): (Span | None) =>
    """
    Where a declaration is written.

    The index holds no spans, so this asks the file that declares it. That
    is the whole trade: a position costs one lookup here, and costs nothing
    when a body is edited.
    """
    match facts(item.file)
    | let known: DocumentFacts =>
      let wanted = item.name()
      for declared in known.declarations.values() do
        if (declared.name == wanted) and (declared.kind is item.kind) then
          return declared.name_span
        end
      end
      None
    end

  fun ref matching(pattern: String val): Array[BoundItem] val =>
    """
    Every declaration in the workspace whose name contains `pattern`,
    ignoring case. What a workspace symbol search asks for.

    An empty pattern matches everything, which is what a client sends to
    populate the picker before anything is typed.
    """
    let wanted: String val = pattern.lower()

    // The package names first, because `index` mutates and the key
    // iterator would be reading the map while it did.
    let packages = Array[String val]
    for package in _files_id.keys() do
      packages.push(package)
    end

    var found = recover iso Array[BoundItem] end
    for package in packages.values() do
      for item in index(package).items.values() do
        let name: String val = item.name().lower()
        if (wanted.size() == 0) or name.contains(wanted) then
          found.push(item)
        end
      end
    end
    consume found

  fun ref run(query: QueryId): Bool =>
    """
    Recompute one query. Called by the engine, never directly.
    """
    let job =
      try
        _job(query)?
      else
        _Unreachable()
        return false
      end
    match \exhaustive\ job.kind
    | _FactsQuery => _run_facts(job.key)
    | _DeclarationsQuery => _run_declarations(job.key)
    | _ImportsQuery => _run_imports(job.key)
    | _IndexQuery => _run_index(job.key)
    | _SourceInput => false
    | _FilesInput => false
    end
    // An input reaches here only when it was demanded before it was ever
    // set. It has no value and nothing changed, and setting it later marks
    // it changed then.

  fun ref _run_facts(file: String val): Bool =>
    _engine.demand(_source_query(file), this)
    let text = try _text(file)? else "" end
    let unchanged = try _facts(file)?.source == text else false end
    if unchanged then
      // A save with no edit, which is a whole revision that costs nothing.
      return false
    end
    _facts(file) = DocumentFacts(text)
    true

  fun ref _run_declarations(file: String val): Bool =>
    _engine.demand(_facts_query(file), this)
    let projected =
      match facts(file)
      | let known: DocumentFacts =>
        _Project(_package_of(file), file, known.declarations)
      else
        recover val Array[BoundItem] end
      end
    let changed =
      try
        not _Same[BoundItem](_declarations(file)?, projected)
      else
        true
      end
    _declarations(file) = projected
    changed

  fun ref _run_imports(file: String val): Bool =>
    _engine.demand(_facts_query(file), this)
    let projected =
      match facts(file)
      | let known: DocumentFacts =>
        recover val
          let out = Array[Import](known.uses.size())
          for used in known.uses.values() do
            out.push(Import(used.package, used.alias))
          end
          out
        end
      else
        recover val Array[Import] end
      end
    let changed =
      try not _Same[Import](_imports(file)?, projected) else true end
    _imports(file) = projected
    changed

  fun ref _run_index(package: String val): Bool =>
    _engine.demand(_files_query(package), this)
    let files = try _files(package)? else recover val Array[String val] end end

    // Sorted, so that the value depends on which files the package has and
    // not on the order a directory walk happened to return them in.
    let ordered =
      Sort[Array[String val], String val](
        recover ref
          let a = Array[String val](files.size())
          for file in files.values() do a.push(file) end
          a
        end)

    var gathered = recover iso Array[BoundItem] end
    for file in ordered.values() do
      for item in declarations(file).values() do
        gathered.push(item)
      end
    end

    let built = PackageIndex(consume gathered)
    let changed = try not (_index(package)? == built) else true end
    _index(package) = built
    changed

  fun ref _source_query(file: String val): QueryId =>
    _lookup(_source_id, _SourceInput, file)

  fun ref _files_query(package: String val): QueryId =>
    _lookup(_files_id, _FilesInput, package)

  fun ref _facts_query(file: String val): QueryId =>
    _lookup(_facts_id, _FactsQuery, file)

  fun ref _declarations_query(file: String val): QueryId =>
    _lookup(_declarations_id, _DeclarationsQuery, file)

  fun ref _imports_query(file: String val): QueryId =>
    _lookup(_imports_id, _ImportsQuery, file)

  fun ref _index_query(package: String val): QueryId =>
    _lookup(_index_id, _IndexQuery, package)

  fun ref _lookup(
    ids: Map[String, QueryId],
    kind: _QueryKind,
    key: String val)
    : QueryId
  =>
    """
    The id for one query, allocating it the first time it is asked for.

    This is the interning the engine leaves to its caller: a query kind and
    a key name one query, and the same pair must always give the same id or
    nothing memoized would ever be found again.
    """
    try
      ids(key)?
    else
      let query = _engine.add()
      ids(key) = query
      _job(query) = _Job(kind, key)
      query
    end

  fun package_for(used: String val, from: String val = ""): String val =>
    """
    The package a `use` locator names.

    A locator beginning with a dot is relative to the package of the file
    that wrote it, which is how one package inside a workspace reaches a
    sibling. Anything else is mapped if the caller said where it is, and
    otherwise taken as naming its package directly.
    """
    if (used.compare_sub(".", 1) is Equal) and (from.size() > 0) then
      _Normalise(_package_of(from) + "/" + used)
    else
      try _package_paths(used)? else used end
    end

  fun _package_of(file: String val): String val =>
    """
    The package a file belongs to, which is the directory holding it.
    """
    try
      let cut = file.rfind("/")?
      file.substring(0, cut)
    else
      ""
    end

primitive _Same[A: Equatable[A] #read]
  """
  Element-wise equality, which is what the engine backdates on.
  """
  fun apply(left: Array[A] val, right: Array[A] val): Bool =>
    if left.size() != right.size() then
      return false
    end
    try
      var i: USize = 0
      while i < left.size() do
        if not (left(i)? == right(i)?) then
          return false
        end
        i = i + 1
      end
      true
    else
      false
    end
