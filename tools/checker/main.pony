use "files"

actor Main
  """
  The batch checker's driver: slice 0 of `SEMANTIC_DESIGN.md`.

  Single mode checks one package directory and exits 0 when there is
  nothing to report, 255 with ponyc-shaped errors otherwise. `--batch`
  reads a file of case directories and emits one verdict line per case —
  `<dir>\t(ok|fail|load-failed)` — sharing one loader across the run so
  the packages under the search roots are parsed once. An internal failure
  exits 1, distinct from both verdicts: a crash must never manufacture
  one.

  At this slice a rejection means a parse diagnostic, an over-deep
  nesting, or a `use`-level legality or resolution error. Everything the
  semantic layer will add lands behind the same verdicts.
  """
  new create(env: Env) =>
    var batch: (String val | None) = None
    var target: (String val | None) = None
    let roots = recover iso Array[String val] end

    for arg in env.args.slice(1).values() do
      if arg.compare_sub("--batch=", 8) is Equal then
        batch = arg.substring(8)
      elseif arg.compare_sub("--path=", 7) is Equal then
        roots.push(arg.substring(7))
      elseif arg.compare_sub("--", 2) is Equal then
        env.err.print("unknown option: " + arg)
        env.exitcode(1)
        return
      else
        target = arg
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
        env.err.print(
          "usage: checker <package-dir> [--path=ROOT ...]\n" +
          "       checker --batch=<cases-file> [--path=ROOT ...]")
        env.exitcode(1)
      end
    end

  fun _diagnostics(program: Program): Array[(CheckDiag, String val)] =>
    """
    Every diagnostic the loaded program carries, paired with the source it
    is located in, in package load order and byte order within a file.
    """
    let out = Array[(CheckDiag, String val)]
    for package in program.packages.values() do
      for file in package.files.values() do
        for d in file.tree.diagnostics.values() do
          out.push((CheckDiag(file.path, d.offset, d.width, d.message),
            file.source))
        end
        for d in CheckLegality(file.path, file.source, file.tree).values() do
          out.push((d, file.source))
        end
      end
    end
    for d in program.load_diags.values() do
      out.push((d, _source_of(program, d.file)))
    end
    out

  fun _source_of(program: Program, path: String val): String val =>
    for package in program.packages.values() do
      for file in package.files.values() do
        if file.path == path then
          return file.source
        end
      end
    end
    ""

  fun _run_single(env: Env, loader: Loader ref, dir: String val) =>
    match loader.load(dir)
    | let e: LoadError =>
      env.err.print("Error:\n" + _load_error(e))
      env.exitcode(255)
    | let program: Program =>
      let diags = _diagnostics(program)
      if diags.size() == 0 then
        env.exitcode(0)
      else
        env.err.print("Error:")
        for (d, source) in diags.values() do
          env.err.print(RenderDiag(d, source))
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
      if line.size() == 0 then
        continue
      end
      let verdict =
        match loader.load(line)
        | let _: LoadError => "load-failed"
        | let program: Program =>
          if _diagnostics(program).size() == 0 then "ok" else "fail" end
        end
      env.out.print(line + "\t" + verdict)
    end
    env.exitcode(0)

  fun _load_error(e: LoadError): String val =>
    match e
    | let u: UnloadableRoot => "couldn't locate this path: " + u.what
    | let u: UnreadableFile => "couldn't read this file: " + u.path
    | let p: EmptyPackage => "no source files in package: " + p.dir
    end
