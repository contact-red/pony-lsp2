use "collections"
use "files"
use "../../../upstream/tools/lib/ponylang/pony_syntax"
use "../../../upstream/tools/lib/ponylang/pony_analysis"

actor \nodoc\ Main
  """
  Corpus checks over the files named on the command line.

  With no flag: dump the non-trivia token kinds of each file, as ponyc's
  token name, for comparison against ponyc's own lexer by `check.py`.

  With `--reprint`: parse each file and report any whose tree does not
  reprint to the source it was built from, and any with more than one root.
  Losslessness over real code rather than over cases someone thought of.

  With `--facts`: project the analysis facts from each file and report any
  declaration with no name, with a count of what was projected.

  With `--tree`: print the parse tree, one indented line per element, so
  that what a rule builds can be read rather than guessed at.

  With `--trivia`: report each file that begins with whitespace or a
  comment rather than with a token that goes in the tree.
  """
  new create(env: Env) =>
    let auth = FileAuth(env.root)
    let args = env.args.slice(1)
    var reprint = false
    var facts_mode = false
    var tree_mode = false
    var trivia_mode = false
    let paths = Array[String]
    for a in args.values() do
      if a == "--reprint" then
        reprint = true
      elseif a == "--facts" then
        facts_mode = true
      elseif a == "--tree" then
        tree_mode = true
      elseif a == "--trivia" then
        trivia_mode = true
      else
        paths.push(a)
      end
    end

    var checked: USize = 0
    var bad: USize = 0
    var diagnosed: USize = 0
    var decls: USize = 0
    var top_level: USize = 0
    var leading: USize = 0

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
          diagnosed = diagnosed + 1
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
          diagnosed = diagnosed + 1
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
      elseif trivia_mode then
        checked = checked + 1
        if _LeadsWithTrivia(src) then
          leading = leading + 1
          env.out.print("TRIVIA " + path)
        end
      elseif tree_mode then
        env.out.print("### " + path)
        let tree = Parse(src)
        for (index, depth, at, kind, width) in tree.walk() do
          let indent =
            recover val
              let out = String(depth * 2)
              for _ in Range(0, depth * 2) do
                out.push(' ')
              end
              out
            end
          let line =
            try
              if tree.is_leaf(index)? then
                " " + _Escape(recover val tree.text(index)? end)
              else
                ""
              end
            else
              ""
            end
          env.out.print(indent + kind.name() + " " + at.string() + "+" +
            width.string() + line)
        end
        for d in tree.diagnostics.values() do
          env.out.print("! " + d.string())
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
      env.out.print("files " + checked.string() +
        ", failures " + bad.string() +
        ", with diagnostics " + diagnosed.string())
    end
    if facts_mode then
      env.out.print("declarations " + decls.string() +
        ", top level " + top_level.string())
    end
    if trivia_mode then
      env.out.print("files " + checked.string() +
        ", beginning with trivia " + leading.string())
    end

primitive \nodoc\ _LeadsWithTrivia
  """
  Whether a source begins with whitespace or a comment.
  """
  fun apply(src: String val): Bool =>
    let stream = recover val TokenStream(src) end
    try
      (let kind, _) = stream(0)?
      match kind
      | TkWhitespace | TkLineComment | TkNestedComment => true
      else
        false
      end
    else
      false
    end

primitive \nodoc\ _Escape
  """
  A leaf's text on one line, so the tree stays readable.
  """
  fun apply(text: String val): String val =>
    recover val
      let out = String(text.size() + 2)
      out.push('\'')
      for c in text.values() do
        match c
        | '\n' => out.append("\\n")
        | '\t' => out.append("\\t")
        else
          out.push(c)
        end
      end
      out.push('\'')
      out
    end
