use "collections"
use "files"
use "../../upstream/tools/lib/ponylang/pony_syntax"

class val UnloadableRoot
  """A target the run cannot start without: the root, or `builtin`."""
  let what: String val
  new val create(what': String val) => what = what'

class val UnreadableFile
  """A file or directory the loader could not read."""
  let path: String val
  new val create(path': String val) => path = path'

class val EmptyPackage
  """A directory with no Pony source files in it."""
  let dir: String val
  new val create(dir': String val) => dir = dir'

primitive _MaxFileBytes
  """
  The largest source file the loader will read: the design's per-file
  byte cap, surfaced as a diagnostic. Roughly ten times the largest file
  in the ponyc tree, and far below the sizes at which a pathological
  file's tree stops being workable.
  """
  fun apply(): USize => 1_048_576

type LoadError is (UnloadableRoot | UnreadableFile | EmptyPackage)
  """
  What stops a load before checking can start. An unresolvable `use`
  inside a loaded program is not one of these: that is an ordinary
  diagnostic and the verdict is `fail`.
  """

class val CheckDiag
  """One diagnostic, located by file and byte span."""
  let file: String val
  let offset: USize
  let width: USize
  let message: String val

  new val create(
    file': String val,
    offset': USize,
    width': USize,
    message': String val)
  =>
    file = file'
    offset = offset'
    width = width'
    message = message'

class val FileData
  """
  One loaded file: its text, its parse, and every per-file projection the
  checker reads, computed once and cached across a batch -- recomputing
  legality per case is what made a corpus run take seconds instead of
  one.
  """
  let path: String val
  let source: String val
  let tree: SyntaxTree val
  let uses: Array[ScannedUse] val
  let legality: Array[CheckDiag] val

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
        [ CheckDiag(path', 0, 0,
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
  A loaded program: the packages reached from the root, in load order, and
  the diagnostics loading itself produced.
  """
  let packages: Array[PackageData] val
  let load_diags: Array[CheckDiag] val

  new val create(
    packages': Array[PackageData] val,
    load_diags': Array[CheckDiag] val)
  =>
    packages = packages'
    load_diags = load_diags'

class Loader
  """
  The one component that reads disk or resolves a `use`.

  Resolution matches ponyc's `find_path` less the upward `pony_packages`
  walk: an absolute path as given; relative to the using package's
  directory, where an explicit `./` or `../` locator that fails there
  fails outright; then each search root in order. A package's identity is
  its canonical directory path, so two locators reaching one directory are
  one package.

  Diagnostics echo whatever the loaded source names, and absolute paths
  are honoured — ponyc parity, decided: running the checker over a
  workspace trusts its dependencies to the degree compiling it would.

  `_store` caches loaded packages by canonical directory across calls,
  which is what makes a batch run parse the standard library once. Sound
  within one run because a canonical path outside the case set maps to
  immutable content.
  """
  let _auth: FileAuth
  let _roots: Array[String val] val
  let _store: Map[String, PackageData val]

  new create(auth: FileAuth, roots: Array[String val] val) =>
    _auth = auth
    _roots = roots
    _store = _store.create()

  fun ref load(target: String val): (Program | LoadError) =>
    let root_dir =
      match _canonical_dir(target)
      | let d: String val => d
      | None => return UnloadableRoot(target)
      end
    let builtin =
      match _resolve_from_roots("builtin")
      | let d: String val => d
      | None => return UnloadableRoot("builtin")
      end

    let ordered = Array[PackageData val]
    let diags = recover iso Array[CheckDiag] end
    let seen = Set[String]
    let queue = Array[String val]

    for dir in [builtin; root_dir].values() do
      if not seen.contains(dir) then
        seen.set(dir)
        queue.push(dir)
      end
    end

    var i: USize = 0
    while i < queue.size() do
      let dir = try queue(i)? else break end
      i = i + 1
      let package =
        match _load_package(dir)
        | let p: PackageData val => p
        | let e: LoadError =>
          // The root and builtin are preconditions; a dependency that
          // resolved but cannot be loaded is a diagnostic in ponyc's
          // wording for what actually went wrong.
          if (dir == root_dir) or (dir == builtin) then
            return e
          end
          let why =
            match e
            | let _: EmptyPackage => "no Pony source files in package"
            else
              "couldn't locate this path"
            end
          diags.push(CheckDiag(dir, 0, 0, why))
          continue
        end
      ordered.push(package)

      for file in package.files.values() do
        for u in file.uses.values() do
          match u.scheme
          | UsePackage =>
            if u.locator.size() == 0 then
              diags.push(
                CheckDiag(file.path, u.offset, u.width,
                  "can't load package ''"))
              continue
            end
            match _resolve(u.locator, dir)
            | let found: String val =>
              if not seen.contains(found) then
                seen.set(found)
                queue.push(found)
              end
            | None =>
              diags.push(
                CheckDiag(file.path, u.offset, u.width,
                  "can't load package '" + u.locator + "'"))
            end
          | UseDirective => None
          | UseUnknown =>
            diags.push(
              CheckDiag(file.path, u.offset, u.width,
                "Use scheme " + u.scheme_text + " not found"))
          end
          if u.guarded and (u.scheme is UsePackage) then
            diags.push(
              CheckDiag(file.path, u.offset, u.width,
                "Use scheme package: may not have a guard"))
          end
          if u.aliased and (u.scheme is UseDirective) then
            diags.push(
              CheckDiag(file.path, u.offset, u.width,
                "Use scheme " + u.scheme_text + " may not have an alias"))
          end
        end
      end
    end

    let packages = recover iso Array[PackageData val] end
    for p in ordered.values() do
      packages.push(p)
    end
    Program(consume packages, consume diags)

  fun ref _load_package(dir: String val): (PackageData val | LoadError) =>
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
      return UnreadableFile(dir)
    end
    if names.size() == 0 then
      return EmptyPackage(dir)
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
          return UnreadableFile(path)
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
