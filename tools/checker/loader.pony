use "collections"
use "files"
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

primitive _MaxFileBytes
  """
  The largest source file the loader will read: the design's per-file
  byte cap, surfaced as a diagnostic. Roughly ten times the largest
  file in the ponyc tree. An over-large file is a rejection of its
  package, where an unreadable one stops the whole load: the first is a
  judgement about the source, the second means the checker never saw
  it.
  """
  fun apply(): USize => 1_048_576

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
  let width: USize
  let message: String val
  let info: (CheckDiagnostic | None)

  new val create(
    file': String val,
    offset': USize,
    width': USize,
    message': String val,
    info': (CheckDiagnostic | None) = None)
  =>
    file = file'
    offset = offset'
    width = width'
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
  One loaded file: its text, its parse, and every per-file projection the
  checker reads, computed once and cached across a batch.
  """
  let path: String val
  let source: String val
  let tree: SyntaxTree val
  let uses: Array[ScannedUse] val
  let legality: Array[CheckDiagnostic] val

  new val create(path': String val, source': String val) =>
    path = path'
    source = source'
    tree = Parse(source')
    uses = ScanUses(tree)
    legality = CheckLegality(path', source', tree)

  new val too_large(path': String val) =>
    """
    A file past the byte cap: never read, one diagnostic.
    """
    path = path'
    source = ""
    tree = Parse("")
    uses = ScanUses(tree)
    legality =
      recover val
        [ CheckDiagnostic(path', 0, 0,
            "this file is larger than the checker's " +
              _MaxFileBytes().string() + " byte limit") ]
      end

class val PackageData
  """
  One loaded package: its canonical directory and its files, in
  bytewise-sorted order, as ponyc loads them.
  """
  let dir: String val
  let files: Array[FileData] val

  new val create(dir': String val, files': Array[FileData] val) =>
    dir = dir'
    files = files'

class val Program
  """
  A loaded program: the packages reached from the root, in load order,
  and what loading itself reported — located diagnostics at `use` sites,
  and unlocated failures for paths and packages no span describes.
  """
  let packages: Array[PackageData] val
  let load_diags: Array[CheckDiagnostic] val
  let load_failures: Array[UnlocatedDiagnostic] val

  new val create(
    packages': Array[PackageData] val,
    load_diags': Array[CheckDiagnostic] val,
    load_failures': Array[UnlocatedDiagnostic] val)
  =>
    packages = packages'
    load_diags = load_diags'
    load_failures = load_failures'

  fun file(path: String val): (FileData | None) =>
    """
    The loaded file at `path`, or `None` when no package holds one.
    """
    for package in packages.values() do
      for f in package.files.values() do
        if f.path == path then
          return f
        end
      end
    end
    None

class Loader
  """
  The one component that reads disk or resolves a `use`.

  Resolution matches ponyc's `find_path` less the upward `pony_packages`
  walk: an absolute path as given; relative to the using package's
  directory, where an explicit `./` or `../` locator that fails there
  fails outright; then each search root in order. A package's identity is
  its canonical directory path, so two locators reaching one directory
  are one package.

  Diagnostics echo whatever the loaded source names, and absolute paths
  are honoured — ponyc parity: a checked workspace's dependencies are
  trusted to the degree compiling it would trust them.

  Loaded packages are cached by canonical directory for the life of the
  `Loader`, and the cache never invalidates: a `load` after a file
  changes on disk returns the package as first read. One `Loader` serves
  one batch over static input; a consumer tracking edits makes a fresh
  one.
  """
  let _auth: FileAuth
  let _roots: Array[String val] val
  let _store: Map[String, PackageData val]

  new create(auth: FileAuth, roots: Array[String val] val) =>
    _auth = auth
    _roots = roots
    _store = _store.create()

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
              CheckDiagnostic(s.file, s.offset, s.width,
                "can't load package '" + locator + "'"))
          end
          continue
        end
      packages.push(package)

      for file in package.files.values() do
        for u in file.uses.values() do
          // ponyc's `uri_command` order: an unknown scheme, then an
          // alias or guard the scheme's row forbids, each stops the
          // `use` before any resolution.
          if u.scheme is UseUnknown then
            diags.push(
              CheckDiagnostic(file.path, u.locator_offset, u.locator_width,
                "Use scheme " + u.scheme_text + " not found"))
            continue
          end
          if u.aliased and (not u.scheme.allow_name()) then
            diags.push(
              CheckDiagnostic(file.path, u.alias_offset, u.alias_width,
                "Use scheme " + u.scheme_text + " may not have an alias"))
            continue
          end
          if u.guarded and (not u.scheme.allow_guard()) then
            // ponyc reports this against the alias clause, present or
            // not, so an unaliased `use` is blamed whole.
            let at = if u.aliased then u.alias_offset else u.offset end
            let width = if u.aliased then u.alias_width else u.width end
            diags.push(
              CheckDiagnostic(file.path, at, width,
                "Use scheme " + u.scheme_text + " may not have a guard"))
            continue
          end
          match u.scheme
          | UsePackage =>
            match _resolve(u.locator, dir)
            | let found: String val =>
              if not seen.contains(found) then
                seen.set(found)
                queue.push(
                  (found, u.locator,
                    _UseSite(file.path, u.offset, u.width)))
              end
            | None =>
              failures.push(
                UnlocatedDiagnostic(
                  u.locator + ": couldn't locate this path"))
              diags.push(
                CheckDiagnostic(file.path, u.offset, u.width,
                  "can't load package '" + u.locator + "'"))
            end
          | UseDirective => None
          end
        end
      end
    end

    Program(consume packages, consume diags, consume failures)

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
      let source =
        try
          let f = OpenFile(FilePath(_auth, path)) as File
          if f.size() > _MaxFileBytes() then
            f.dispose()
            files.push(FileData.too_large(path))
            continue
          end
          let text: String val =
            recover val String.from_array(f.read(f.size())) end
          f.dispose()
          text
        else
          return UnreadableFile(path, "can't open file " + path)
        end
      files.push(FileData(path, source))
    end
    let built = PackageData(dir, consume files)
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
  The span of the `use` a failed dependency load is reported against.
  """
  let file: String val
  let offset: USize
  let width: USize

  new val create(file': String val, offset': USize, width': USize) =>
    file = file'
    offset = offset'
    width = width'
