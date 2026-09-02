use "collections"
use "files"
use "../../upstream/tools/lib/ponylang/pony_analysis"
use "../../upstream/tools/lib/ponylang/pony_syntax"

class val UnloadableRoot
  """A target the run cannot start without: the root, or `builtin`."""
  let what: String val
  new val create(what': String val) => what = what'
  fun string(): String val => what + ": couldn't locate this path"

class val UnreadableFile
  """A file or directory that exists but could not be read."""
  let path: String val
  let why: String val
  new val create(path': String val, why': String val) =>
    path = path'
    why = why'
  fun string(): String val => path + ": " + why

class val EmptyPackage
  """
  A directory with no Pony source files in it, named as the program
  names it: the locator of the `use` that reached it, or the target as
  typed.
  """
  let name: String val
  new val create(name': String val) => name = name'
  fun string(): String val =>
    "no Pony source files in package '" + name + "'"

type LoadError is (UnloadableRoot | UnreadableFile | EmptyPackage)
  """
  What stops a load before checking can start. An unresolvable `use`
  inside a loaded program is not one of these: that is an ordinary
  diagnostic and the verdict is `fail`. Each variant renders itself in
  ponyc's wording via `string()`.
  """

class val CheckDiagnostic
  """
  One diagnostic, located by file and byte span. `info` is a secondary
  note rendered as ponyc's indented `Info:` block.
  """
  let file: String val
  let offset: USize
  let message: String val
  let info: (CheckDiagnostic | None)

  new val create(
    file': String val,
    offset': USize,
    message': String val,
    info': (CheckDiagnostic | None) = None)
  =>
    file = file'
    offset = offset'
    message = message'
    info = info'

class val UnlocatedDiagnostic
  """
  A diagnostic with no source position: a load failure reported about a
  path or a package rather than a span of source. Rendered as its
  message alone, which carries ponyc's wording for the condition.
  """
  let message: String val
  new val create(message': String val) => message = message'
  fun string(): String val => message

class val FileData
  """
  One loaded file: its parse and every per-file projection the checker
  reads, computed once and cached across a batch. The parse arrives
  through `DocumentFacts`, the projection the language server also
  reads.
  """
  let path: String val
  let facts: DocumentFacts
  let tree: SyntaxTree val
  let uses: Array[ScannedUse] val
  let legality: Array[CheckDiagnostic] val

  new val create(path': String val, source: String val) =>
    path = path'
    // DocumentFacts rather than a bare parse: name resolution needs
    // its scope-aware bindings, which are not separable from the
    // projections the checker never reads — those are computed and
    // retained as the price.
    facts = DocumentFacts(source, Utf8)
    tree = facts.tree()
    uses = ScanUses(tree)
    legality = CheckLegality(path', tree, facts.offsets())

class val PackageData
  """
  One loaded package: its files, in bytewise-sorted order, as ponyc
  loads them, and the package-level legality only the whole package
  can decide. Its identity is the canonical directory path the
  loader's store keys it by.
  """
  let files: Array[FileData] val
  let legality: Array[CheckDiagnostic] val

  new val create(files': Array[FileData] val) =>
    files = files'
    legality = _PackageLegality(files')

primitive _PackageLegality
  """
  ponyc's package-docstring rule: one module docstring becomes the
  package's, and every other one is an error naming it. ponyc builds
  the package by prepending modules, so the docstring that wins is the
  bytewise-last file's.
  """
  fun apply(files: Array[FileData] val): Array[CheckDiagnostic] val =>
    recover val
      let out = Array[CheckDiagnostic]
      var existing: (CheckDiagnostic | None) = None
      var i = files.size()
      while i > 0 do
        i = i - 1
        try
          let file = files(i)?
          match _module_docstring(file)
          | let doc: CheckDiagnostic =>
            match existing
            | None => existing = doc
            | let first: CheckDiagnostic =>
              out.push(
                CheckDiagnostic(doc.file, doc.offset,
                  "the package already has a docstring",
                  CheckDiagnostic(first.file, first.offset,
                    "the existing docstring is here")))
            end
          end
        end
      end
      out
    end

  fun _module_docstring(file: FileData): (CheckDiagnostic | None) =>
    """
    The module's docstring: a string as the module's first statement.
    The carried message is only a position; the caller writes its own.
    """
    let tree = file.tree
    try
      for child in tree.children(0)? do
        match tree.kind(child)?
        | TkWhitespace | TkLineComment | TkNestedComment => None
        | TkString =>
          return CheckDiagnostic(file.path, tree.offset(child)?, "")
        else
          return None
        end
      end
    end
    None

class val Program
  """
  A loaded program: the packages reached from the root, in load order;
  what loading itself reported — located diagnostics at `use` sites,
  and unlocated failures for paths and packages no span describes —
  and the staged rule families computed once the load completed.
  """
  let packages: Array[PackageData] val
  let _load_diags: Array[CheckDiagnostic] val
  let _load_failures: Array[UnlocatedDiagnostic] val
  let _parse_clean: Bool
    """
    Whether every loaded file parsed without a diagnostic. Computed
    once by the loader, which also skips the whole-program checks
    when it is false — one predicate, so the skip and the ladder
    cannot disagree.
    """
  let _rungs_open: Bool
    """
    Whether the ladder is still open past the load rung: no parse,
    legality or load report closed it. Also computed once by the
    loader, which skips computing the families when it is false for
    the same reason the parse skip exists: their walks would find
    rules the ladder then discards.
    """
  let _rungs: Array[(Bool, Array[CheckDiagnostic] val)] val
    """
    The staged families past the load rung, in ponyc's pass order —
    the ladder as one value, so the order exists in one place. Each
    entry is whether a report there closes the rungs after it, and
    the family. These report only through `diagnostics`, which walks
    them in order.
    """

  new val create(
    packages': Array[PackageData] val,
    load_diags': Array[CheckDiagnostic] val,
    load_failures': Array[UnlocatedDiagnostic] val,
    rungs': Array[(Bool, Array[CheckDiagnostic] val)] val,
    parse_clean': Bool,
    rungs_open': Bool)
  =>
    packages = packages'
    _load_diags = load_diags'
    _load_failures = load_failures'
    _rungs = rungs'
    _parse_clean = parse_clean'
    _rungs_open = rungs_open'

  fun parse_failed(): Bool =>
    """
    Whether any loaded file failed to parse. ponyc's later passes do
    not run after a parse error, so a consumer reports only the parse
    diagnostics when this holds.
    """
    not _parse_clean

  fun diagnostics(): Array[(FileData, Array[CheckDiagnostic])] =>
    """
    Every located diagnostic, grouped and sorted: packages in load
    order, files in package order, byte order within a file, staged
    the way ponyc's passes are — the first pass that errors is the
    last that runs. Parse diagnostics report alone; legality and
    load share the next rung, since ponyc resolves and loads a
    `use` while it reads the package in. `_rungs` holds the order
    past that, and whether a report on each rung closes the rungs
    after it. ponyc's name pass stops reporting at its first real
    error where the checker reports the whole family. The
    load-then-nothing-later rule is load-bearing beyond parity: a
    dependency that resolves but
    fails to load has no entity table, so its importers' lookups
    past the load rung would not find the names that package
    declares — the `can't load package` diagnostic is what
    suppresses them. The unlocated failures are not here;
    `failures()` stages them, and they render first.
    """
    let with_load = not parse_failed()
    var open = _rungs_open
    let included = Array[Array[CheckDiagnostic] val]
    for (closes, family) in _rungs.values() do
      if open then
        included.push(family)
        if closes and (family.size() > 0) then
          open = false
        end
      end
    end
    // Grouped by file up front, so the walk below is linear in the
    // diagnostics rather than rescanning every array per file.
    let by_file = Map[String, Array[CheckDiagnostic]]
    if with_load then
      for package in packages.values() do
        for d in package.legality.values() do
          try by_file(d.file)?.push(d) else by_file(d.file) = [d] end
        end
      end
      for d in _load_diags.values() do
        try by_file(d.file)?.push(d) else by_file(d.file) = [d] end
      end
    end
    for family in included.values() do
      for d in family.values() do
        try by_file(d.file)?.push(d) else by_file(d.file) = [d] end
      end
    end
    let out = Array[(FileData, Array[CheckDiagnostic])]
    for package in packages.values() do
      for f in package.files.values() do
        let diags = Array[CheckDiagnostic]
        for d in f.tree.diagnostics.values() do
          diags.push(CheckDiagnostic(f.path, d.offset, d.message))
        end
        if with_load then
          for d in f.legality.values() do
            diags.push(d)
          end
        end
        try
          for d in by_file(f.path)?.values() do
            diags.push(d)
          end
        end
        _SortByOffset(diags)
        out.push((f, diags))
      end
    end
    out

  fun failures(): Array[UnlocatedDiagnostic] val =>
    """
    The unlocated load failures, staged the same way `diagnostics`
    is: they sit on the load rung beside legality, as in ponyc, which
    resolves a `use` while reading the package in — only a parse
    failure reports without them.
    """
    if parse_failed() then
      recover val Array[UnlocatedDiagnostic] end
    else
      _load_failures
    end

class Loader
  """
  The one component that reads disk or resolves a `use`, and the
  driver of the whole-program checks: once a load completes, it
  computes each package's reuse, import-clash, name and provides
  diagnostics over its caches.

  Resolution matches ponyc's `find_path` less the upward `pony_packages`
  walk: an absolute path as given; relative to the using package's
  directory, where an explicit `./` or `../` locator that fails there
  fails outright; then each search root in order. A package's identity is
  its canonical directory path, so two locators reaching one directory
  are one package.

  Diagnostics echo whatever the loaded source names, and absolute paths
  are honoured — ponyc parity: a checked workspace's dependencies are
  trusted to the degree compiling it would trust them.

  Loaded packages, their per-file imports, their entity tables,
  their entity sites, and each rule family's diagnostics are cached
  by canonical directory for the life of the `Loader`, and none of
  the caches invalidates: a
  `load` after a file changes on disk returns the package as first
  read. A failed load stores nothing, so an unreadable or empty
  directory is read again on each later `load` of it. One `Loader`
  serves one batch over static input; a consumer tracking edits
  makes a fresh one.
  """
  let _auth: FileAuth
  let _roots: Array[String val] val
  var _builtin: (String val | None) = None
    """Where `builtin` resolved, once `load` first needed it."""
  let _store: Map[String, PackageData val]
  let _imports: Map[String, Map[String, _PackageImports] val]
    """Per-file resolved imports, cached by package directory."""
  let _entities: Map[String, Map[String, _EntityInfo] val]
    """Entity tables, cached by package directory."""
  let _names: Map[String, _NameFamilies]
    """Name diagnostics, cached by package directory."""
  let _sites: Map[String, _PackageEntities val]
    """Entity declaration sites, cached by package directory."""
  let _reuse:
    Map[String,
      (Array[CheckDiagnostic] val, Array[CheckDiagnostic] val)]
    """Reuse diagnostics, cached by package directory."""
  let _clash: Map[String, Array[CheckDiagnostic] val]
    """Import-clash diagnostics, cached by package directory."""
  let _provides:
    Map[String,
      (Array[CheckDiagnostic] val, Array[CheckDiagnostic] val)]
    """Provides diagnostics, cached by package directory."""
  let _files: Bool
    """
    Whether to report each file as it is opened, in ponyc's wording.
    """

  new create(
    auth: FileAuth,
    roots: Array[String val] val,
    files: Bool = false)
  =>
    _auth = auth
    _roots = roots
    _store = _store.create()
    _imports = _imports.create()
    _entities = _entities.create()
    _names = _names.create()
    _sites = _sites.create()
    _reuse = _reuse.create()
    _clash = _clash.create()
    _provides = _provides.create()
    _files = files

  fun ref load(target: String val): (Program | LoadError) =>
    """
    Load the package at `target` and everything it reaches through
    `use`, returning the program in load order, or the `LoadError` that
    stopped the load before checking could start.
    """
    let root_dir =
      match _resolve(target, ".")
      | let d: String val => d
      | None => return UnloadableRoot(target)
      end
    let builtin =
      match _builtin_dir()
      | let d: String val => d
      | None => return UnloadableRoot("builtin")
      end

    let packages = recover iso Array[PackageData val] end
    let package_dirs = Array[String val]
    let diags = recover iso Array[CheckDiagnostic] end
    let failures = recover iso Array[UnlocatedDiagnostic] end
    let seen = Set[String]
    // Each entry is a resolved directory, the locator that first named
    // it, and for a dependency the `use` site a failed load is
    // reported against, as in ponyc's scope pass.
    let queue = Array[(String val, String val, (_UseSite | None))]

    for (dir, locator) in
      [(builtin, "builtin"); (root_dir, target)].values()
    do
      if not seen.contains(dir) then
        seen.set(dir)
        queue.push((dir, locator, None))
      end
    end

    var i: USize = 0
    while i < queue.size() do
      (let dir, let locator, let site) = try queue(i)? else break end
      i = i + 1
      let package =
        match _load_package(dir, locator)
        | let p: PackageData val => p
        | let e: LoadError =>
          match site
          | None =>
            // The root and builtin are preconditions of the run, and
            // their errors already carry the locator as typed.
            return e
          | let s: _UseSite =>
            failures.push(UnlocatedDiagnostic(e.string()))
            diags.push(
              CheckDiagnostic(s.file, s.offset,
                "can't load package '" + locator + "'"))
          end
          continue
        end
      packages.push(package)
      package_dirs.push(dir)

      let file_imports =
        if _imports.contains(dir) then
          // This package's imports were recorded by an earlier load;
          // the use walk below still runs for its diagnostics and to
          // reach its dependencies.
          None
        else
          Map[String, _PackageImports]
        end
      // ponyc prepends each parsed module, so its whole-package
      // passes see files in descending byte order; walking the uses
      // that way lands a once-per-package diagnostic on the file
      // ponyc blames.
      var file_i = package.files.size()
      while file_i > 0 do
        file_i = file_i - 1
        let file = try package.files(file_i)? else _Unreachable(); break end
        let aliases = Map[String, String val]
        let opens = Array[_OpenImport]
        for u in file.uses.values() do
          // ponyc's `uri_command` order: an unknown scheme, then an
          // alias or guard the scheme's row forbids, each stops the
          // `use` before any resolution.
          if u.scheme is UseUnknown then
            diags.push(
              CheckDiagnostic(file.path, u.locator_offset,
                "Use scheme " + u.scheme_text + " not found"))
            continue
          end
          match u.alias
          | let a: UseAlias if not u.scheme.allow_name() =>
            diags.push(
              CheckDiagnostic(file.path, a.offset,
                "Use scheme " + u.scheme_text + " may not have an alias"))
            continue
          end
          if u.guarded and (not u.scheme.allow_guard()) then
            // ponyc reports this against the alias clause, present or
            // not, so an unaliased `use` is blamed whole.
            let at =
              match u.alias
              | let a: UseAlias => a.offset
              | None => u.offset
              end
            diags.push(
              CheckDiagnostic(file.path, at,
                "Use scheme " + u.scheme_text + " may not have a guard"))
            continue
          end
          match u.scheme
          | UsePackage =>
            match _resolve(u.locator, dir)
            | let found: String val =>
              if file_imports isnt None then
                match u.alias
                | let a: UseAlias =>
                  // ponyc's symbol table keeps the first binding.
                  aliases.insert_if_absent(a.name, found)
                | None =>
                  opens.push(
                    _OpenImport(found,
                      _UseSite(file.path, u.offset), u.locator))
                end
              end
              if not seen.contains(found) then
                seen.set(found)
                queue.push(
                  (found, u.locator, _UseSite(file.path, u.offset)))
              end
            | None =>
              failures.push(
                UnlocatedDiagnostic(
                  u.locator + ": couldn't locate this path"))
              diags.push(
                CheckDiagnostic(file.path, u.offset,
                  "can't load package '" + u.locator + "'"))
            end
          | UseDirective => None
          end
        end
        match file_imports
        | let fi: Map[String, _PackageImports] =>
          fi(file.path) =
            _PackageImports(
              _freeze_aliases(aliases), _freeze_opens(opens),
              builtin)
        end
      end
      match file_imports
      | let fi: Map[String, _PackageImports] =>
        _imports(dir) = _freeze_imports(fi)
      end
    end

    _check_program(
      package_dirs, consume packages, consume diags,
      consume failures)

  fun ref _check_program(
    package_dirs: Array[String val] box,
    packages: Array[PackageData] val,
    diags: Array[CheckDiagnostic] val,
    failures: Array[UnlocatedDiagnostic] val)
    : Program
  =>
    """
    The whole-program checks, run once the load is complete so
    every loaded package has its entity table, assembled into the
    Program's ladder. The answers are cached with the package,
    whose content cannot change within a run.
    """
    // In ladder order, matching the pushes below.
    let reuse = recover iso Array[CheckDiagnostic] end
    let clash = recover iso Array[CheckDiagnostic] end
    let type_private = recover iso Array[CheckDiagnostic] end
    let type_names = recover iso Array[CheckDiagnostic] end
    let entity_provides = recover iso Array[CheckDiagnostic] end
    let refer = recover iso Array[CheckDiagnostic] end
    let expr_private = recover iso Array[CheckDiagnostic] end
    let expr_reuse = recover iso Array[CheckDiagnostic] end
    let object_provides = recover iso Array[CheckDiagnostic] end
    // A parse failure discards everything past the parse rung, so
    // the whole-program checks are skipped, not computed and thrown
    // away — a file that does not parse projects recovery trees the
    // rules would walk for nothing.
    var parse_clean = true
    for package in packages.values() do
      for f in package.files.values() do
        if f.tree.diagnostics.size() > 0 then
          parse_clean = false
          break
        end
      end
      if not parse_clean then
        break
      end
    end
    // The same reasoning covers the rest of the shared rung: a
    // legality or load report also closes the ladder before any
    // family here, so their walks are skipped too.
    var shared_rung_clean =
      (diags.size() == 0) and (failures.size() == 0)
    if shared_rung_clean then
      for package in packages.values() do
        if package.legality.size() > 0 then
          shared_rung_clean = false
          break
        end
        for f in package.files.values() do
          if f.legality.size() > 0 then
            shared_rung_clean = false
            break
          end
        end
      end
    end
    let rungs_open = parse_clean and shared_rung_clean
    if rungs_open then
      for pkg_dir in package_dirs.values() do
        (let scope_reuse, let island_reuse) = _package_reuse(pkg_dir)
        for d in scope_reuse.values() do
          reuse.push(d)
        end
        for d in island_reuse.values() do
          expr_reuse.push(d)
        end
        for d in _package_clash(pkg_dir).values() do
          clash.push(d)
        end
        let fams = _package_names(pkg_dir)
        for d in fams.type_names.values() do
          type_names.push(d)
        end
        for d in fams.type_private.values() do
          type_private.push(d)
        end
        for d in fams.refer.values() do
          refer.push(d)
        end
        for d in fams.expr_private.values() do
          expr_private.push(d)
        end
        (let from_entities, let from_objects) =
          _package_provides(pkg_dir)
        for d in from_entities.values() do
          entity_provides.push(d)
        end
        for d in from_objects.values() do
          object_provides.push(d)
        end
      end
    end

    // The two private-type families report without failing their
    // ponyc pass, so they close nothing.
    let rungs = recover iso Array[(Bool, Array[CheckDiagnostic] val)] end
    rungs.push((true, recover val consume reuse end))
    rungs.push((true, recover val consume clash end))
    rungs.push((false, recover val consume type_private end))
    rungs.push((true, recover val consume type_names end))
    rungs.push((true, recover val consume entity_provides end))
    rungs.push((true, recover val consume refer end))
    // One ponyc pass is one rung: the three expr-pass families
    // report together; the last is marked closing though nothing
    // follows it.
    rungs.push((false, recover val consume expr_private end))
    rungs.push((false, recover val consume expr_reuse end))
    rungs.push((true, recover val consume object_provides end))

    Program(
      packages, diags, failures, consume rungs
      where parse_clean' = parse_clean, rungs_open' = rungs_open)

  fun ref _package_names(dir: String val): _NameFamilies =>
    """
    The unresolved-name diagnostics for one loaded package, computed
    once per loader — `CheckNames`' four families, named for their
    rungs.
    """
    try
      return _names(dir)?
    end
    let empty: Array[CheckDiagnostic] val =
      recover val Array[CheckDiagnostic] end
    let package =
      try
        _store(dir)?
      else
        _Unreachable()
        return _NameFamilies(empty, empty, empty, empty)
      end
    let imports =
      try
        _imports(dir)?
      else
        _Unreachable()
        return _NameFamilies(empty, empty, empty, empty)
      end
    _ensure_entities(dir)
    for fi in imports.values() do
      _ensure_entities(fi.builtin)
      for open in fi.opens.values() do
        _ensure_entities(open.dir)
      end
      for alias_dir in fi.aliases.values() do
        _ensure_entities(alias_dir)
      end
    end
    let type_names = recover iso Array[CheckDiagnostic] end
    let type_private = recover iso Array[CheckDiagnostic] end
    let refer = recover iso Array[CheckDiagnostic] end
    let expr_private = recover iso Array[CheckDiagnostic] end
    for file in package.files.values() do
      let fi =
        try
          imports(file.path)?
        else
          _Unreachable()
          continue
        end
      let fams = CheckNames(file, dir, fi, _entities)
      for d in fams.type_names.values() do
        type_names.push(d)
      end
      for d in fams.type_private.values() do
        type_private.push(d)
      end
      for d in fams.refer.values() do
        refer.push(d)
      end
      for d in fams.expr_private.values() do
        expr_private.push(d)
      end
    end
    let built =
      _NameFamilies(
        recover val consume type_names end,
        recover val consume type_private end,
        recover val consume refer end,
        recover val consume expr_private end)
    _names(dir) = built
    built

  fun ref _package_sites(dir: String val): _PackageEntities val =>
    """
    The package's entity declaration sites in ponyc's processing
    order, computed once per loader.
    """
    try
      return _sites(dir)?
    end
    let built: _PackageEntities val =
      try
        _PackageEntities(_store(dir)?.files)
      else
        _Unreachable()
        _PackageEntities(recover val Array[FileData] end)
      end
    _sites(dir) = built
    built

  fun ref _package_reuse(dir: String val)
    : (Array[CheckDiagnostic] val, Array[CheckDiagnostic] val)
  =>
    """
    The reuse diagnostics for one loaded package, the scope-pass
    and expr-pass families separately: its duplicate entities, each
    file's duplicate aliases, then each file's members, type
    parameters and locals. Two aliases collide only when they bind
    different packages — ponyc's symbol table treats
    rebinding a name to the value it already holds as a success, and
    an alias binds the loaded package itself — so the rule needs the
    resolver and lives here. An alias whose locator does not resolve
    binds nothing and fails open; its `can't load package` outranks
    this rung anyway.
    """
    try
      return _reuse(dir)?
    end
    let empty: Array[CheckDiagnostic] val =
      recover val Array[CheckDiagnostic] end
    let package =
      try
        _store(dir)?
      else
        _Unreachable()
        return (empty, empty)
      end
    let sites = _package_sites(dir)
    let out = recover iso Array[CheckDiagnostic] end
    let expr_out = recover iso Array[CheckDiagnostic] end
    for (dup, prev) in sites.duplicates().values() do
      out.push(CheckReuse.duplicate(dup, prev))
    end
    for file in package.files.values() do
      // Duplicate aliases, reported without an Info line as every
      // alias reuse is.
      let alias_dirs = Map[String, String]
      for u in file.uses.values() do
        if u.scheme isnt UsePackage then
          continue
        end
        match u.alias
        | let a: UseAlias =>
          match _resolve(u.locator, dir)
          | let found: String val =>
            let fold = _Fold(a.name)
            match try alias_dirs(fold)? else None end
            | let first: String val =>
              if first != found then
                out.push(
                  CheckReuse.alias_clash(file.path, a.offset, a.name))
              end
            | None =>
              alias_dirs(fold) = found
            end
          end
        end
      end
      (let from_scope, let from_islands) = CheckReuse(file, sites)
      for d in from_scope.values() do
        out.push(d)
      end
      for d in from_islands.values() do
        expr_out.push(d)
      end
    end
    let built =
      (recover val consume out end, recover val consume expr_out end)
    _reuse(dir) = built
    built

  fun ref _package_clash(dir: String val)
    : Array[CheckDiagnostic] val
  =>
    """
    ponyc's import-pass clash rules for one package: per file, each
    unaliased `use` against builtin, the package's own entities, and
    the file's earlier opens — first clashing `use` per file — and
    each own entity against an importable builtin name. ponyc stops
    its whole compile at the first clashing `use` and reports that
    use's symbols in an unstable order; the checker reports every
    file's first clash, its symbols rendered in byte order like
    every diagnostic.
    """
    try
      return _clash(dir)?
    end
    let empty: Array[CheckDiagnostic] val =
      recover val Array[CheckDiagnostic] end
    let builtin =
      match _builtin_dir()
      | let d: String val => d
      | None =>
        // `load` resolved builtin before any package was stored.
        _Unreachable()
        return empty
      end
    let package =
      try
        _store(dir)?
      else
        _Unreachable()
        return empty
      end
    let imports =
      try
        _imports(dir)?
      else
        _Unreachable()
        return empty
      end
    let own_sites = _package_sites(dir)
    let out = recover iso Array[CheckDiagnostic] end
    if dir != builtin then
      let builtin_sites = _package_sites(builtin)
      // An own entity named after a builtin type, case-folded as
      // ponyc's lookup is; a private builtin name is never imported,
      // so it clashes with nothing. ponyc stops its compile at the
      // first clashing use, so a dependency's own clash here is one
      // it never reaches — the checker reports every package's.
      for site in own_sites.all().values() do
        match builtin_sites.by_fold(_Fold(site.name))
        | let b: _EntitySite if _Importable(b.name) =>
          out.push(
            CheckDiagnostic(site.file, site.keyword_offset,
              "type name clashes with builtin type"
              where info' = CheckDiagnostic(b.file,
                b.keyword_offset, "builtin type here")))
        end
      end
      var file_i = package.files.size()
      while file_i > 0 do
        file_i = file_i - 1
        let file =
          try
            package.files(file_i)?
          else
            _Unreachable()
            break
          end
        let fi = try imports(file.path)? else _Unreachable(); continue end
        // The file's scope is a chain, looked up case-folded as
        // ponyc's symbol tables are: names earlier opens added, the
        // package's own entities — which shadow builtin's — and
        // builtin's importable names. Only the first link is built
        // here; the other two are each package's cached fold map.
        // A dir already in scope is skipped — ponyc clashes a
        // repeated import of one package with itself, and the
        // checker deliberately fails open there instead.
        let opened = Set[String]
        opened.set(builtin)
        opened.set(dir)
        let added = Map[String, _EntitySite]
        for open in fi.opens.values() do
          let use_site = open.site
          if not _store.contains(open.dir) then
            // A failed load closes the ladder before this rung
            // runs, so this cannot arise; kept so an unforeseen
            // path fails open instead of crashing on the lookup.
            continue
          end
          if opened.contains(open.dir) then
            continue
          end
          opened.set(open.dir)
          let open_sites = _package_sites(open.dir)
          let clashes = Array[(_EntitySite, _EntitySite)]
          // One pass: a fold that misses the chain is exactly the
          // one to add, a hit is exactly a clash; a clash breaks
          // before anything reads what was added.
          for (fold, incoming) in open_sites.folded().values() do
            if not _Importable(incoming.name) then
              continue
            end
            let held =
              try
                added(fold)?
              else
                // Own entities are in scope unfiltered: a private
                // or `Main` entity clashes with nothing importable
                // anyway. Builtin's private names are never
                // imported.
                match own_sites.by_fold(fold)
                | let own: _EntitySite => own
                | None =>
                  match builtin_sites.by_fold(fold)
                  | let b: _EntitySite if _Importable(b.name) =>
                    b
                  else
                    added.insert_if_absent(fold, incoming)
                    continue
                  end
                end
              end
            clashes.push((held, incoming))
          end
          if clashes.size() > 0 then
            out.push(
              CheckDiagnostic(use_site.file, use_site.offset,
                "can't use '" + open.locator +
                  "' without alias, clashing symbols"))
            for (prev, incoming) in clashes.values() do
              out.push(
                CheckDiagnostic(prev.file, prev.keyword_offset,
                  "existing type name clashes with type from '" +
                    open.locator + "'"
                  where info' = CheckDiagnostic(incoming.file,
                    incoming.keyword_offset,
                    "clash trying to use this type")))
            end
            break
          end

        end
      end
    end
    let frozen: Array[CheckDiagnostic] val = consume out
    _clash(dir) = frozen
    frozen

  fun ref _package_provides(dir: String val)
    : (Array[CheckDiagnostic] val, Array[CheckDiagnostic] val)
  =>
    """
    The invalid-provides diagnostics for one loaded package —
    entity clauses and object-literal clauses separately. Unlike
    `_package_names`, alias directories get no entity tables here:
    the provides rule returns early on a qualified name, so it
    never looks one up.
    """
    try
      return _provides(dir)?
    end
    let empty: Array[CheckDiagnostic] val =
      recover val Array[CheckDiagnostic] end
    let package =
      try
        _store(dir)?
      else
        _Unreachable()
        return (empty, empty)
      end
    let imports =
      try
        _imports(dir)?
      else
        _Unreachable()
        return (empty, empty)
      end
    _ensure_entities(dir)
    for fi in imports.values() do
      _ensure_entities(fi.builtin)
      for open in fi.opens.values() do
        _ensure_entities(open.dir)
      end
    end
    let from_entities = recover iso Array[CheckDiagnostic] end
    let from_objects = recover iso Array[CheckDiagnostic] end
    for file in package.files.values() do
      let fi = try imports(file.path)? else _Unreachable(); continue end
      (let e, let o) = CheckProvides(file, dir, fi, _entities)
      for d in e.values() do
        from_entities.push(d)
      end
      for d in o.values() do
        from_objects.push(d)
      end
    end
    let built =
      (recover val consume from_entities end,
        recover val consume from_objects end)
    _provides(dir) = built
    built

  fun ref _ensure_entities(dir: String val) =>
    if not _entities.contains(dir) then
      // A resolved dir whose package failed to load is absent from
      // the store; its `can't load package` diagnostic suppresses
      // name reporting, so no table is needed.
      try
        _entities(dir) = _ProjectEntities(_store(dir)?.files)
      end
    end

  fun _freeze_opens(opens: Array[_OpenImport] box)
    : Array[_OpenImport] val
  =>
    let out = recover iso Array[_OpenImport](opens.size()) end
    for o in opens.values() do
      out.push(o)
    end
    consume out

  fun _freeze_aliases(aliases: Map[String, String val] box)
    : Map[String, String val] val
  =>
    let out = recover iso Map[String, String val] end
    for (k, v) in aliases.pairs() do
      out(k) = v
    end
    consume out

  fun _freeze_imports(imports: Map[String, _PackageImports] box)
    : Map[String, _PackageImports] val
  =>
    let out = recover iso Map[String, _PackageImports] end
    for (k, v) in imports.pairs() do
      out(k) = v
    end
    consume out

  fun ref _load_package(dir: String val, locator: String val)
    : (PackageData val | LoadError)
  =>
    try
      return _store(dir)?
    end
    let names = Array[String val]
    try
      let entries = Directory(FilePath(_auth, dir))?.entries()?
      for entry in (consume entries).values() do
        // ponyc's filter: a .pony suffix, not hidden, and not a
        // directory that happens to carry the suffix.
        if (entry.size() > 5) and
          (entry.compare_sub(".pony", 5, (entry.size() - 5).isize())
            is Equal) and
          (not (entry.compare_sub(".", 1) is Equal))
        then
          let path = Path.join(dir, entry)
          let is_dir =
            try
              FileInfo(FilePath(_auth, path))?.directory
            else
              false
            end
          if not is_dir then
            names.push(path)
          end
        end
      end
    else
      // The directory resolved but would not list. ponyc splits
      // this by errno; the files package does not carry one, so a
      // stat of the path stands in for the conditions errno
      // distinguishes.
      let why =
        try
          if FileInfo(FilePath(_auth, dir))?.directory then
            "permission denied"
          else
            "not a directory"
          end
        else
          "does not exist"
        end
      return UnreadableFile(dir, why)
    end
    if names.size() == 0 then
      return EmptyPackage(locator)
    end
    Sort[Array[String val], String val](names)

    let files = recover iso Array[FileData val] end
    for path in names.values() do
      if _files then
        // ponyc's wording.
        _Stderr.print("Opening " + path)
      end
      let source =
        try
          let f = OpenFile(FilePath(_auth, path)) as File
          let text: String val =
            recover val String.from_array(f.read(f.size())) end
          f.dispose()
          text
        else
          return UnreadableFile(path, "can't open file " + path)
        end
      files.push(FileData(path, source))
    end
    let built = PackageData(consume files)
    _store(dir) = built
    built

  fun _resolve(locator: String val, from_dir: String val)
    : (String val | None)
  =>
    if Path.is_abs(locator) then
      return _canonical_dir(locator)
    end
    let explicit_relative =
      (locator.compare_sub("./", 2) is Equal) or
        (locator.compare_sub("../", 3) is Equal)
    match _canonical_dir(Path.join(from_dir, locator))
    | let d: String val => return d
    end
    if explicit_relative then
      // ponyc's rule: an explicitly relative locator that fails against
      // the using package never falls through to the roots.
      return None
    end
    _resolve_from_roots(locator)

  fun ref _builtin_dir(): (String val | None) =>
    """
    Where `builtin` resolved, memoised — the roots are fixed at
    construction, so the answer cannot change within a run.
    """
    match _builtin
    | let d: String val => return d
    end
    match _resolve_from_roots("builtin")
    | let d: String val =>
      _builtin = d
      d
    | None => None
    end

  fun _resolve_from_roots(locator: String val): (String val | None) =>
    for root in _roots.values() do
      match _canonical_dir(Path.join(root, locator))
      | let d: String val => return d
      end
    end
    None

  fun _canonical_dir(path: String val): (String val | None) =>
    try
      let canonical: String val = Path.canonical(path)?
      if FileInfo(FilePath(_auth, canonical))?.directory then
        canonical
      else
        None
      end
    else
      None
    end

class val _OpenImport
  """
  One unaliased package `use` as a file wrote it: where it resolved,
  the written locator, and the `use` site the import-clash rule
  reports at.
  """
  let dir: String val
    """The canonical directory the locator resolved to."""
  let site: _UseSite
  let locator: String val

  new val create(
    dir': String val,
    site': _UseSite,
    locator': String val)
  =>
    dir = dir'
    site = site'
    locator = locator'

class val _UseSite
  """
  The `use` a failed dependency load or an import clash is reported
  against.
  """
  let file: String val
  let offset: USize

  new val create(file': String val, offset': USize) =>
    file = file'
    offset = offset'

primitive _FreezeDiags
  """
  A `val` copy of a diagnostics array — every rule family builds one
  mutably and returns it frozen.
  """
  fun apply(out: Array[CheckDiagnostic] box)
    : Array[CheckDiagnostic] val
  =>
    let frozen = recover iso Array[CheckDiagnostic](out.size()) end
    for d in out.values() do
      frozen.push(d)
    end
    consume frozen

primitive _SortStrings
  """
  An in-place ascending sort of strings — insertion sort, since the
  inputs are small key sets.
  """
  fun apply(keys: Array[String val] ref) =>
    var i: USize = 1
    while i < keys.size() do
      let held = try keys(i)? else _Unreachable(); return end
      var back = i
      while
        (back > 0) and
          ((try keys(back - 1)? else _Unreachable(); held end)
            .compare(held) is Greater)
      do
        try
          keys(back)? = keys(back - 1)?
        else
          _Unreachable()
        end
        back = back - 1
      end
      try keys(back)? = held else _Unreachable() end
      i = i + 1
    end

primitive _SortByOffset
  """
  Stable sort of diagnostics by byte offset, in place.
  """
  fun apply(diags: Array[CheckDiagnostic]) =>
    if diags.size() < 2 then
      return
    end
    let aux = Array[CheckDiagnostic](diags.size())
    for d in diags.values() do
      aux.push(d)
    end
    _merge_sort(aux, diags, 0, diags.size())

  fun _merge_sort(
    from: Array[CheckDiagnostic],
    to: Array[CheckDiagnostic],
    lo: USize,
    hi: USize)
  =>
    """
    Sort `from`'s range into `to`'s, ping-ponging the two arrays so each
    level merges without a copy. The ranges hold the same elements on
    entry.
    """
    if (hi - lo) < 2 then
      return
    end
    let mid = (lo + hi) / 2
    _merge_sort(to, from, lo, mid)
    _merge_sort(to, from, mid, hi)
    var i = lo
    var j = mid
    var k = lo
    try
      while k < hi do
        if (j >= hi) or
          ((i < mid) and (from(i)?.offset <= from(j)?.offset))
        then
          to.update(k, from(i)?)?
          i = i + 1
        else
          to.update(k, from(j)?)?
          j = j + 1
        end
        k = k + 1
      end
    else
      _Unreachable()
    end
