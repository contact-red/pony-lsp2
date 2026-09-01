use "collections"
use "files"
use "../../upstream/tools/lib/ponylang/pony_syntax"

type _Renderable is
  ((CheckDiagnostic, LineIndex val, (LineIndex val | None)) | String val)
  """
  One stderr item awaiting `_render_chunk`: a diagnostic with the
  indexes that place it, or a message already in its final form.
  """

actor Main
  """
  The batch checker's driver.

  Single mode checks one package directory and exits 0 when there is
  nothing to report, 255 with ponyc-shaped errors otherwise. `--batch`
  reads a file of case directories and emits one verdict line per case —
  `<dir>\t(ok|fail|load-failed)` — sharing one loader across the run so
  the packages under the search roots are parsed once. A usage error and
  an internal failure both exit 1, distinct from both verdicts, so a
  crash is never read as one.

  A rejection means a parse diagnostic, over-deep nesting, a
  `use`-level legality or resolution error, one of the ported
  syntax-pass legality rules, or an unresolved name. Diagnostics are
  staged as in ponyc, whose later passes do not run after an error;
  `Program.diagnostics` holds the rule.

  Both loops run in chunks of behaviours rather than one call, so a
  long batch or a diagnostic-heavy file is collected as it goes instead
  of holding every allocation to the end.
  """
  let _env: Env
  var _loader: (Loader | None) = None
  var _cases: Array[String val] val = recover val Array[String val] end
  var _case_index: USize = 0
  var _batch_errors: Bool = false
  embed _render_queue: Array[_Renderable] = _render_queue.create()
  var _render_index: USize = 0

  new create(env: Env) =>
    _env = env
    var batch: (String val | None) = None
    var target: (String val | None) = None
    var verbose = false
    var errors = false
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
        let value: String val = arg.substring(8)
        if value.size() == 0 then
          env.err.print("--batch needs a value")
          env.exitcode(1)
          return
        end
        batch = value
      elseif arg == "--batch" then
        match try args(n)? else None end
        | let value: String val
          if (value.size() > 0) and
            (try value(0)? != '-' else false end)
        =>
          n = n + 1
          batch = value
        else
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
        | let value: String val
          if (value.size() > 0) and
            (try value(0)? != '-' else false end)
        =>
          n = n + 1
          for entry in Path.split_list(value).values() do
            if entry.size() > 0 then
              roots.push(entry)
            end
          end
        else
          env.err.print("--path needs a value")
          env.exitcode(1)
          return
        end
      elseif arg == "--verbose" then
        verbose = true
      elseif arg == "--errors" then
        errors = true
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

    let loader = Loader(FileAuth(env.root), consume roots, verbose)
    _loader = loader

    match batch
    | let list: String val =>
      _batch_errors = errors
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
      "usage: checker <package-dir> [--path=ROOT ...] [--verbose]\n" +
      "       checker --batch=<cases-file> [--path=ROOT ...] [--verbose]" +
      " [--errors]\n" +
      "--verbose reports each file as it is opened.\n" +
      "--errors renders each fail or load-failed batch case's" +
      " diagnostics; single mode always renders them.\n" +
      "PONYPATH entries are search roots too, after every --path.")

  fun _count(
    program: Program,
    groups: Array[(FileData, Array[CheckDiagnostic])] box)
    : USize
  =>
    """
    How many diagnostics the program reports, from the same grouping
    the renderer walks.
    """
    var n: USize = program.failures().size()
    for (_, diags) in groups.values() do
      n = n + diags.size()
    end
    n

  fun _index_for(
    program: Program,
    path: String val,
    cache: Map[String, LineIndex val])
    : (LineIndex val | None)
  =>
    try
      return cache(path)?
    end
    for package in program.packages.values() do
      for f in package.files.values() do
        if f.path == path then
          let index: LineIndex val = LineIndex(f.tree.source, Utf8)
          cache(path) = index
          return index
        end
      end
    end
    None

  fun ref _queue_program(
    program: Program,
    groups: Array[(FileData, Array[CheckDiagnostic])] box)
    : Bool
  =>
    """
    Queue everything the program reports — the staged load failures,
    then each file's diagnostics — for `_render_chunk` to render.
    Returns true when anything was queued.
    """
    let before = _render_queue.size()
    for f in program.failures().values() do
      _render_queue.push(f.string())
    end
    let indexes = Map[String, LineIndex val]
    for (file, diags) in groups.values() do
      if diags.size() > 0 then
        let index: LineIndex val = LineIndex(file.tree.source, Utf8)
        indexes(file.path) = index
        for d in diags.values() do
          // An Info naming another file — the package-docstring
          // rule — renders against that file's own index.
          let info_index =
            match d.info
            | let info: CheckDiagnostic if info.file != d.file =>
              _index_for(program, info.file, indexes)
            else
              None
            end
          _render_queue.push((d, index, info_index))
        end
      end
    end
    _render_queue.size() > before

  fun ref _run_single(loader: Loader ref, dir: String val) =>
    match loader.load(dir)
    | let e: LoadError =>
      _Stderr.print("Error:\n" + e.string())
      _env.exitcode(255)
    | let program: Program =>
      if _queue_program(program, program.diagnostics()) then
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
        // ponyc prints an `Error:` heading per diagnostic.
        match _render_queue(_render_index)?
        | (let d: CheckDiagnostic, let index: LineIndex val,
          let info_index: (LineIndex val | None))
        =>
          _Stderr.print("Error:\n" + RenderDiag(d, index, info_index))
        | let s: String val =>
          _Stderr.print("Error:\n" + s)
        end
      end
      _render_index = _render_index + 1
      n = n + 1
    end
    if _render_index < _render_queue.size() then
      _render_chunk()
    else
      _render_queue.clear()
      _render_index = 0
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
    while
      (n < 32) and (_case_index < _cases.size()) and
      // Let the renderer catch up before loading more cases, so the
      // queue holds at most a chunk's worth of diagnostics.
      ((_render_queue.size() - _render_index) <= 256)
    do
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
        | let e: LoadError =>
          if _batch_errors then
            _render_queue.push(e.string())
          end
          "load-failed"
        | let program: Program =>
          let groups = program.diagnostics()
          if _count(program, groups) == 0 then
            "ok"
          else
            if _batch_errors then
              _queue_program(program, groups)
            end
            "fail"
          end
        end
      _env.out.print(case_dir + "\t" + verdict)
    end
    if _render_index < _render_queue.size() then
      _render_chunk()
    end
    if _case_index < _cases.size() then
      _batch_chunk()
    else
      _env.exitcode(0)
    end
