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
  of the ported syntax-pass legality rules. When any file fails to
  parse, only the parse diagnostics report, as in ponyc, whose later
  passes do not run after a parse error.

  Both loops run in chunks of behaviours rather than one call, so a
  long batch or a diagnostic-heavy file is collected as it goes instead
  of holding every allocation to the end.
  """
  let _env: Env
  var _loader: (Loader | None) = None
  var _cases: Array[String val] val = recover val Array[String val] end
  var _case_index: USize = 0
  embed _render_queue: Array[(CheckDiagnostic, LineIndex val)] =
    _render_queue.create()
  var _render_index: USize = 0

  new create(env: Env) =>
    _env = env
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
      elseif arg == "--batch" then
        match try args(n)? else None end
        | let value: String val =>
          n = n + 1
          batch = value
        | None =>
          env.err.print("--batch needs a value")
          env.exitcode(1)
          return
        end
      elseif arg.compare_sub("--path=", 7) is Equal then
        let value: String val = arg.substring(7)
        if value.size() == 0 then
          env.err.print("--path needs a value")
          env.exitcode(1)
          return
        end
        // ponyc splits the value on the platform's list separator.
        for entry in Path.split_list(value).values() do
          if entry.size() > 0 then
            roots.push(entry)
          end
        end
      elseif arg == "--path" then
        match try args(n)? else None end
        | let value: String val =>
          n = n + 1
          for entry in Path.split_list(value).values() do
            if entry.size() > 0 then
              roots.push(entry)
            end
          end
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

    match (batch, target)
    | (let _: String val, let extra: String val) =>
      env.err.print("unexpected argument with --batch: " + extra)
      env.exitcode(1)
      return
    end

    let loader = Loader(FileAuth(env.root), consume roots)
    _loader = loader

    match batch
    | let list: String val =>
      _start_batch(list)
    else
      match target
      | let dir: String val =>
        _run_single(loader, dir)
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

  fun _parse_failed(program: Program): Bool =>
    for package in program.packages.values() do
      for file in package.files.values() do
        if file.tree.diagnostics.size() > 0 then
          return true
        end
      end
    end
    false

  fun _grouped(program: Program)
    : Array[(FileData, Array[CheckDiagnostic])]
  =>
    """
    Every located diagnostic the loaded program carries, grouped and
    sorted: packages in load order, files in package order, byte order
    within a file. When any file failed to parse, only the parse
    diagnostics are included, as in ponyc, whose later passes do not
    run after a parse error. Verdict counting and rendering both read
    this one grouping, so they cannot disagree.
    """
    let parse_failed = _parse_failed(program)
    let out = Array[(FileData, Array[CheckDiagnostic])]
    for package in program.packages.values() do
      for file in package.files.values() do
        let diags = Array[CheckDiagnostic]
        for d in file.tree.diagnostics.values() do
          diags.push(
            CheckDiagnostic(file.path, d.offset, d.width, d.message))
        end
        if not parse_failed then
          for d in file.legality.values() do
            diags.push(d)
          end
          for d in program.load_diags.values() do
            if d.file == file.path then
              diags.push(d)
            end
          end
        end
        _SortByOffset(diags)
        out.push((file, diags))
      end
    end
    out

  fun _verdict_count(program: Program): USize =>
    """
    How many diagnostics single mode would render, from the same
    grouping it renders.
    """
    var n: USize =
      if _parse_failed(program) then 0
      else program.load_failures.size() end
    for (_, diags) in _grouped(program).values() do
      n = n + diags.size()
    end
    n

  fun ref _run_single(loader: Loader ref, dir: String val) =>
    match loader.load(dir)
    | let e: LoadError =>
      _env.err.print("Error:\n" + e.string())
      _env.exitcode(255)
    | let program: Program =>
      var any = false
      if not _parse_failed(program) then
        // ponyc prints an `Error:` heading per diagnostic.
        for f in program.load_failures.values() do
          _Stderr.print("Error:\n" + f.string())
          any = true
        end
      end
      for (file, diags) in _grouped(program).values() do
        if diags.size() > 0 then
          let index: LineIndex val = LineIndex(file.source, Utf8)
          for d in diags.values() do
            _render_queue.push((d, index))
          end
        end
      end
      if any or (_render_queue.size() > 0) then
        _env.exitcode(255)
        _render_chunk()
      else
        _env.exitcode(0)
      end
    end

  be _render_chunk() =>
    """
    Render a bounded slice of the queue per behaviour, so the strings a
    diagnostic-heavy file produces are collected as the run goes.
    """
    var n: USize = 0
    while (n < 256) and (_render_index < _render_queue.size()) do
      try
        (let d, let index) = _render_queue(_render_index)?
        _Stderr.print("Error:\n" + RenderDiag(d, index))
      end
      _render_index = _render_index + 1
      n = n + 1
    end
    if _render_index < _render_queue.size() then
      _render_chunk()
    end

  fun ref _start_batch(list: String val) =>
    let cases: Array[String val] val =
      try
        let f = OpenFile(FilePath(FileAuth(_env.root), list)) as File
        let text: String val =
          recover val String.from_array(f.read(f.size())) end
        f.dispose()
        text.split_by("\n")
      else
        _env.err.print("cannot read batch list: " + list)
        _env.exitcode(1)
        return
      end
    _cases = cases
    _batch_chunk()

  be _batch_chunk() =>
    """
    Check a bounded slice of the case list per behaviour, so a long
    batch's garbage is collected as the run goes instead of held to
    the end.
    """
    let loader =
      match _loader
      | let l: Loader => l
      | None => return
      end
    var n: USize = 0
    while (n < 32) and (_case_index < _cases.size()) do
      let line = try _cases(_case_index)? else "" end
      _case_index = _case_index + 1
      n = n + 1
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
          if _verdict_count(program) == 0 then "ok" else "fail" end
        end
      _env.out.print(case_dir + "\t" + verdict)
    end
    if _case_index < _cases.size() then
      _batch_chunk()
    else
      _env.exitcode(0)
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
