use "collections"
use "files"
use "../../upstream/tools/lib/ponylang/pony_analysis"
use "../../upstream/tools/lib/ponylang/pony_bind"

actor \nodoc\ Main
  new create(env: Env) =>
    let auth = FileAuth(env.root)
    let args = env.args.slice(1)
    if args.size() < 2 then
      env.out.print("usage: bind_check <packages-root> <file.pony>...")
      return
    end

    let root = try args(0)? else return end
    let binder: Binder ref = Binder
    let by_package = Map[String, Array[String val]]

    var read: USize = 0
    for i in Range(1, args.size()) do
      let path = try args(i)? else continue end
      let text =
        try
          let file = OpenFile(FilePath(auth, path)) as File
          recover val String.from_array(file.read(file.size())) end
        else
          continue
        end
      read = read + 1
      binder.set_source(path, text)
      let package = _Dirname(path)
      by_package.insert_if_absent(package, Array[String val])
      try by_package(package)?.push(path) end
    end

    for (package, files) in by_package.pairs() do
      binder.set_files(package, _Freeze(files))
      // ponyc resolves `use "collections/persistent"` against the packages
      // root, so the path a `use` writes is the directory relative to it.
      if package.at(root, 0) and (package.size() > (root.size() + 1)) then
        binder.set_package_path(
          package.substring((root.size() + 1).isize()), package)
      end
    end
    binder.set_builtin(root + "/builtin")

    var entities: USize = 0
    var unresolved: USize = 0
    var wrong_file: USize = 0
    var uses: USize = 0
    var unknown_package: USize = 0
    var bindings: USize = 0
    var not_itself: USize = 0
    var shown: USize = 0

    for (package, files) in by_package.pairs() do
      for file in files.values() do
        for item in binder.declarations(file).values() do
          if not item.is_entity() then
            continue
          end
          entities = entities + 1
          match binder.resolve(file, item.name())
          | let found: BoundItem =>
            if found.file != file then
              // Two packages may declare the same name; only a mismatch
              // inside one package is a fault.
              if _Dirname(found.file) == package then
                wrong_file = wrong_file + 1
                if shown < 10 then
                  shown = shown + 1
                  env.out.print(
                    "WRONGFILE " + item.name() + " in " + file +
                    " resolved to " + found.file)
                end
              end
            end
          else
            unresolved = unresolved + 1
            if shown < 10 then
              shown = shown + 1
              env.out.print("UNRESOLVED " + item.name() + " in " + file)
            end
          end
        end

        // Every binding, asked about at its own name, must come back as
        // itself. Ground truth without a compiler: the document says where
        // the name is written, and resolution has to agree.
        match binder.facts(file)
        | let known: DocumentFacts =>
          for bound in known.bindings.values() do
            bindings = bindings + 1
            match binder.resolve_at(
              file, bound.name_span.start_line, bound.name_span.start_character)
            | let same: Binding =>
              if same.name_span.start_character
                != bound.name_span.start_character
              then
                not_itself = not_itself + 1
                if shown < 10 then
                  shown = shown + 1
                  env.out.print(
                    "NOTITSELF " + bound.name + " at " +
                    bound.name_span.string() + " in " + file)
                end
              end
            else
              not_itself = not_itself + 1
              if shown < 10 then
                shown = shown + 1
                env.out.print(
                  "UNBOUND " + bound.name + " at " +
                  bound.name_span.string() + " in " + file)
              end
            end
          end
        end

        for used in binder.imports(file).values() do
          uses = uses + 1
          let named = binder.package_for(used.package, file)
          if binder.index(named).size() == 0 then
            unknown_package = unknown_package + 1
            if shown < 10 then
              shown = shown + 1
              env.out.print("UNKNOWNPKG " + used.package + " from " + file)
            end
          end
        end
      end
    end

    env.out.print(
      "files " + read.string() +
      ", packages " + by_package.size().string() +
      ", revision " + binder.revision().string())
    env.out.print(
      "entities " + entities.string() +
      ", unresolved " + unresolved.string() +
      ", wrong file " + wrong_file.string())
    env.out.print(
      "uses " + uses.string() + ", naming no known package " +
      unknown_package.string())
    env.out.print(
      "bindings " + bindings.string() +
      ", not resolving to themselves " + not_itself.string())

primitive \nodoc\ _Dirname
  fun apply(path: String val): String val =>
    try
      path.substring(0, path.rfind("/")?)
    else
      ""
    end

primitive \nodoc\ _Freeze
  fun apply(files: Array[String val] box): Array[String val] val =>
    var out = recover iso Array[String val](files.size()) end
    for file in files.values() do
      out.push(file)
    end
    consume out
