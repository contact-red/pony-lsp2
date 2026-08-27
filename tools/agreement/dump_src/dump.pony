use "files"
use "../../../upstream/tools/lib/ponylang/pony_syntax"
use "../../../upstream/tools/lib/ponylang/pony_analysis"

actor \nodoc\ Main
  """
  Two corpus checks over the files named on the command line.

  With no flag: dump the non-trivia token kinds of each file, as ponyc's
  token name, for comparison against ponyc's own lexer by `check.py`.

  With `--reprint`: parse each file and report any whose tree does not
  reprint to the source it was built from, and any with more than one root.
  Losslessness over real code rather than over cases someone thought of.
  """
  new create(env: Env) =>
    let auth = FileAuth(env.root)
    let args = env.args.slice(1)
    var reprint = false
    var facts_mode = false
    let paths = Array[String]
    for a in args.values() do
      if a == "--reprint" then
        reprint = true
      elseif a == "--facts" then
        facts_mode = true
      else
        paths.push(a)
      end
    end

    var checked: USize = 0
    var bad: USize = 0
    var decls: USize = 0
    var top_level: USize = 0

    for path in paths.values() do
      let src =
        try
          let file = OpenFile(FilePath(auth, path)) as File
          recover val String.from_array(file.read(file.size())) end
        else
          continue
        end

      if facts_mode then
        checked = checked + 1
        let facts = DocumentFacts(src)
        for d in facts.declarations.values() do
          if d.name.size() == 0 then
            bad = bad + 1
            env.out.print("UNNAMED " + d.kind.name() + " in " + path +
              " at " + d.span.string())
          end
        end
        if facts.diagnostics.size() > 0 then
          bad = bad + 1
          env.out.print("DIAGNOSTICS " + path)
        end
        for d in facts.declarations.values() do
          if d.container is None then
            top_level = top_level + 1
          end
        end
        decls = decls + facts.declarations.size()
      elseif reprint then
        checked = checked + 1
        let tree = Parse(src)
        if tree.reprint() != src then
          bad = bad + 1
          env.out.print("REPRINT " + path)
        end
        if tree.diagnostics.size() > 0 then
          bad = bad + 1
          env.out.print("DIAGNOSTICS " + path + " (" +
            tree.diagnostics.size().string() + ")")
          var shown: USize = 0
          for d in tree.diagnostics.values() do
            if shown < 2 then
              env.out.print("  " + d.string())
              shown = shown + 1
            end
          end
        end
        try
          if tree.subtree_size(0)? != tree.size() then
            bad = bad + 1
            env.out.print("MULTIROOT " + path)
          end
        else
          if src.size() > 0 then
            bad = bad + 1
            env.out.print("NOROOT " + path)
          end
        end
      else
        env.out.print("### " + path)
        let stream = recover val TokenStream(src) end
        for (kind, offset, width) in stream.values() do
          match kind
          | TkWhitespace | TkLineComment | TkNestedComment | TkEof => None
          else
            env.out.print(kind.ponyc_name() + "\t" + offset.string())
          end
        end
      end
    end

    if reprint or facts_mode then
      env.out.print("files " + checked.string() + ", failures " + bad.string())
    end
    if facts_mode then
      env.out.print("declarations " + decls.string() +
        ", top level " + top_level.string())
    end
