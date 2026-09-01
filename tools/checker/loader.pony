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
  and the name diagnostics computed once the load completed.
  """
  let packages: Array[PackageData] val
  let _load_diags: Array[CheckDiagnostic] val
  let _load_failures: Array[UnlocatedDiagnostic] val
  let _name_diags: Array[CheckDiagnostic] val
    """
    Unresolved-name diagnostics, reported only through `diagnostics`,
    which stages them after everything earlier.
    """

  new val create(
    packages': Array[PackageData] val,
    load_diags': Array[CheckDiagnostic] val,
    load_failures': Array[UnlocatedDiagnostic] val,
    name_diags': Array[CheckDiagnostic] val)
  =>
    packages = packages'
    _load_diags = load_diags'
    _load_failures = load_failures'
    _name_diags = name_diags'

  fun parse_failed(): Bool =>
    """
    Whether any loaded file failed to parse. ponyc's later passes do
    not run after a parse error, so a consumer reports only the parse
    diagnostics when this holds.
    """
    for package in packages.values() do
      for f in package.files.values() do
        if f.tree.diagnostics.size() > 0 then
          return true
        end
      end
    end
    false

  fun diagnostics(): Array[(FileData, Array[CheckDiagnostic])] =>
    """
    Every located diagnostic, grouped and sorted: packages in load
    order, files in package order, byte order within a file, staged
    the way ponyc's passes are — the first pass that errors is the
    last that runs. When any file failed to parse, only the parse
    diagnostics are included; the unresolved-name diagnostics are
    included only when no parse, legality, package or load diagnostic
    exists anywhere in the program. That last rule is load-bearing
    beyond parity: a dependency that resolves but fails to load has
    no entity table, so its importers' name lookups would not find
    the names that package declares — the `can't load package`
    diagnostic that failure raises is what suppresses them. The
    unlocated failures are not here; `failures()` stages them, and
    they render first.
    """
    let suppress = parse_failed()
    var earlier = _load_diags.size() > 0
    if not earlier then
      for package in packages.values() do
        if package.legality.size() > 0 then
          earlier = true
        end
        for f in package.files.values() do
          if f.legality.size() > 0 then
            earlier = true
          end
        end
      end
    end
    let with_names = (not suppress) and (not earlier)
    let out = Array[(FileData, Array[CheckDiagnostic])]
    for package in packages.values() do
      for f in package.files.values() do
        let diags = Array[CheckDiagnostic]
        for d in f.tree.diagnostics.values() do
          diags.push(CheckDiagnostic(f.path, d.offset, d.message))
        end
        if not suppress then
          for d in f.legality.values() do
            diags.push(d)
          end
          for d in package.legality.values() do
            if d.file == f.path then
              diags.push(d)
            end
          end
          for d in _load_diags.values() do
            if d.file == f.path then
              diags.push(d)
            end
          end
        end
        if with_names then
          for d in _name_diags.values() do
            if d.file == f.path then
              diags.push(d)
            end
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
    is: after a parse failure only the parse diagnostics report, so
    none of these.
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
  computes each package's name diagnostics over its caches.

  Resolution matches ponyc's `find_path` less the upward `pony_packages`
  walk: an absolute path as given; relative to the using package's
  directory, where an explicit `./` or `../` locator that fails there
  fails outright; then each search root in order. A package's identity is
  its canonical directory path, so two locators reaching one directory
  are one package.

  Diagnostics echo whatever the loaded source names, and absolute paths
  are honoured — ponyc parity: a checked workspace's dependencies are
  trusted to the degree compiling it would trust them.

  Loaded packages, their per-file imports, their entity tables and
  their name diagnostics are each cached by canonical directory for
  the life of the `Loader`, and none of the caches invalidates: a
  `load` after a file changes on disk returns the package as first
  read. One `Loader` serves one batch over static input; a consumer
  tracking edits makes a fresh one.
  """
  let _auth: FileAuth
  let _roots: Array[String val] val
  let _store: Map[String, PackageData val]
  let _imports: Map[String, Map[String, _PackageImports] val]
    """Per-file resolved imports, cached by package directory."""
  let _entities: Map[String, Map[String, _EntityInfo] val]
    """Entity tables, cached by package directory."""
  let _names: Map[String, Array[CheckDiagnostic] val]
    """Name diagnostics, cached by package directory."""
  let _verbose: Bool

  new create(
    auth: FileAuth,
    roots: Array[String val] val,
    verbose: Bool = false)
  =>
    _auth = auth
    _roots = roots
    _store = _store.create()
    _imports = _imports.create()
    _entities = _entities.create()
    _names = _names.create()
    _verbose = verbose

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
      match _resolve_from_roots("builtin")
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
        let opens = Array[String val]
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
          if u.aliased and (not u.scheme.allow_name()) then
            diags.push(
              CheckDiagnostic(file.path, u.alias_offset,
                "Use scheme " + u.scheme_text + " may not have an alias"))
            continue
          end
          if u.guarded and (not u.scheme.allow_guard()) then
            // ponyc reports this against the alias clause, present or
            // not, so an unaliased `use` is blamed whole.
            let at = if u.aliased then u.alias_offset else u.offset end
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
                if u.aliased and (u.alias_name.size() > 0) then
                  aliases(u.alias_name) = found
                elseif not u.aliased then
                  opens.push(found)
                else
                  _Unreachable()
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
          opens.push(builtin)
          fi(file.path) =
            _PackageImports(
              _freeze_aliases(aliases), _freeze_dirs(opens))
        end
      end
      match file_imports
      | let fi: Map[String, _PackageImports] =>
        _imports(dir) = _freeze_imports(fi)
      end
    end

    // Name resolution runs once the whole program is loaded, so every
    // package that loaded has its entity table; the answers are
    // cached with the package, whose content cannot change within a
    // run.
    let names = recover iso Array[CheckDiagnostic] end
    for pkg_dir in package_dirs.values() do
      for d in _package_names(pkg_dir).values() do
        names.push(d)
      end
    end

    Program(
      consume packages, consume diags, consume failures, consume names)

  fun ref _package_names(dir: String val)
    : Array[CheckDiagnostic] val
  =>
    """
    The unresolved-name diagnostics for one loaded package, computed
    once per loader: the package's entity table and those of its
    imports feed `CheckNames` over each file.
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
        return empty
      end
    let imports =
      try
        _imports(dir)?
      else
        _Unreachable()
        return empty
      end
    _ensure_entities(dir)
    for fi in imports.values() do
      for open_dir in fi.opens.values() do
        _ensure_entities(open_dir)
      end
      for alias_dir in fi.aliases.values() do
        _ensure_entities(alias_dir)
      end
    end
    let out = recover iso Array[CheckDiagnostic] end
    for file in package.files.values() do
      let fi =
        try
          imports(file.path)?
        else
          _Unreachable()
          continue
        end
      for d in CheckNames(file, dir, fi, _entities).values() do
        out.push(d)
      end
    end
    let frozen: Array[CheckDiagnostic] val = consume out
    _names(dir) = frozen
    frozen

  fun ref _ensure_entities(dir: String val) =>
    if not _entities.contains(dir) then
      // A resolved dir whose package failed to load is absent from
      // the store; its `can't load package` diagnostic suppresses
      // name reporting, so no table is needed.
      try
        _entities(dir) = _ProjectEntities(_store(dir)?.files)
      end
    end

  fun _freeze_dirs(dirs: Array[String val] box): Array[String val] val =>
    let out = recover iso Array[String val](dirs.size()) end
    for d in dirs.values() do
      out.push(d)
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
      // The directory resolved but would not list. ponyc splits this by
      // errno; the files package does not carry one, so the probe
      // covers the conditions stat distinguishes.
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
      if _verbose then
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

class val _UseSite
  """
  The `use` a failed dependency load is reported against.
  """
  let file: String val
  let offset: USize

  new val create(file': String val, offset': USize) =>
    file = file'
    offset = offset'

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
