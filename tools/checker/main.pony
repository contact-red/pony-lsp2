use "files"
use "../../upstream/tools/lib/ponylang/pony_syntax"

actor Main
  """
  The batch checker's driver: slice 0 of `SEMANTIC_DESIGN.md`.

  Single mode checks one package directory and exits 0 when there is
  nothing to report, 255 with ponyc-shaped errors otherwise. `--batch`
  reads a file of case directories and emits one verdict line per case —
  `<dir>\t(ok|fail|load-failed)` — sharing one loader across the run so
  the packages under the search roots are parsed once. A usage error and
  an internal failure both exit 1, distinct from both verdicts, so a
  crash is never read as one.

  At this slice a rejection means a parse diagnostic, an over-deep or
  over-large source, a `use`-level legality or resolution error, or one
  of the ported syntax-pass legality rules.
  """
  new create(env: Env) =>
    var batch: (String val | None) = None
    var target: (String val | None) = None
    let roots = recover iso Array[String val] end

    let args = env.args
    var n: USize = 1
    while n < args.size() do
      let arg = try args(n)? else break end
      n = n + 1
      if (arg == "--help") or (arg == "-h") then
        _usage(env.out)
        return
      elseif arg.compare_sub("--batch=", 8) is Equal then
        batch = arg.substring(8)
      elseif arg.compare_sub("--path=", 7) is Equal then
        let value: String val = arg.substring(7)
        if value.size() == 0 then
          env.err.print("--path needs a value")
          env.exitcode(1)
          return
        end
        roots.push(value)
      elseif arg == "--path" then
        match try args(n)? else None end
        | let value: String val =>
          n = n + 1
          roots.push(value)
        | None =>
          env.err.print("--path needs a value")
          env.exitcode(1)
          return
        end
      elseif arg.compare_sub("--", 2) is Equal then
        env.err.print("unknown option: " + arg)
        env.exitcode(1)
        return
      else
        match target
        | None => target = arg
        | let _: String val =>
          env.err.print("unexpected argument: " + arg)
          env.exitcode(1)
          return
        end
      end
    end
    for v in env.vars.values() do
      if v.compare_sub("PONYPATH=", 9) is Equal then
        for entry in Path.split_list(v.substring(9)).values() do
          if entry.size() > 0 then
            roots.push(entry)
          end
        end
      end
    end

    let loader = Loader(FileAuth(env.root), consume roots)

    match batch
    | let list: String val =>
      _run_batch(env, loader, list)
    else
      match target
      | let dir: String val =>
        _run_single(env, loader, dir)
      | None =>
        _usage(env.err)
        env.exitcode(1)
      end
    end

  fun _usage(out: OutStream) =>
    out.print(
      "usage: checker <package-dir> [--path=ROOT ...]\n" +
      "       checker --batch=<cases-file> [--path=ROOT ...]\n" +
      "PONYPATH entries are search roots too, after every --path.")

  fun _diagnostics(program: Program)
    : Array[(CheckDiagnostic, LineIndex val)]
  =>
    """
    Every located diagnostic the loaded program carries, paired with its
    file's line index: packages in load order, files in package order,
    and byte order within a file. The unlocated failures in
    `program.load_failures` are not here; they render first, before any
    located diagnostic.
    """
    let out = Array[(CheckDiagnostic, LineIndex val)]
    for package in program.packages.values() do
      for file in package.files.values() do
        let diags = Array[CheckDiagnostic]
        for d in file.tree.diagnostics.values() do
          diags.push(
            CheckDiagnostic(file.path, d.offset, d.width, d.message))
        end
        for d in file.legality.values() do
          diags.push(d)
        end
        for d in program.load_diags.values() do
          if d.file == file.path then
            diags.push(d)
          end
        end
        _SortByOffset(diags)
        let index: LineIndex val = LineIndex(file.source, Utf8)
        for d in diags.values() do
          out.push((d, index))
        end
      end
    end
    out

  fun _diagnostic_count(program: Program): USize =>
    """
    How many diagnostics `_run_single` would render, without building
    the render pairing — the batch driver needs only the verdict.
    """
    var n: USize =
      program.load_failures.size() + program.load_diags.size()
    for package in program.packages.values() do
      for file in package.files.values() do
        n = n + file.tree.diagnostics.size() + file.legality.size()
      end
    end
    n

  fun _run_single(env: Env, loader: Loader ref, dir: String val) =>
    match loader.load(dir)
    | let e: LoadError =>
      env.err.print("Error:\n" + e.string())
      env.exitcode(255)
    | let program: Program =>
      let located = _diagnostics(program)
      if (program.load_failures.size() + located.size()) == 0 then
        env.exitcode(0)
      else
        env.err.print("Error:")
        for f in program.load_failures.values() do
          env.err.print(f.string())
        end
        for (d, index) in located.values() do
          env.err.print(RenderDiag(d, index))
        end
        env.exitcode(255)
      end
    end

  fun _run_batch(env: Env, loader: Loader ref, list: String val) =>
    let cases: Array[String val] val =
      try
        let f = OpenFile(FilePath(FileAuth(env.root), list)) as File
        let text: String val =
          recover val String.from_array(f.read(f.size())) end
        f.dispose()
        text.split_by("\n")
      else
        env.err.print("cannot read batch list: " + list)
        env.exitcode(1)
        return
      end
    for line in cases.values() do
      let case_dir: String val =
        // A batch list written on Windows carries a `\r` before each
        // newline; it is never part of the directory name.
        if try line(line.size() - 1)? == '\r' else false end then
          line.substring(0, line.size().isize() - 1)
        else
          line
        end
      if case_dir.size() == 0 then
        continue
      end
      let verdict =
        match loader.load(case_dir)
        | let _: LoadError => "load-failed"
        | let program: Program =>
          if _diagnostic_count(program) == 0 then "ok" else "fail" end
        end
      env.out.print(case_dir + "\t" + verdict)
    end
    env.exitcode(0)

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
