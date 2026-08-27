use "files"
use "../../../pony_syntax"

actor \nodoc\ Main
  """
  Dump the non-trivia tokens of each file given, as ponyc's token name and
  the exact source text, tab separated. Compared against ponyc's own lexer
  by `tools/agreement/check.py`.
  """
  new create(env: Env) =>
    let auth = FileAuth(env.root)
    for path in env.args.slice(1).values() do
      try
        let file = OpenFile(FilePath(auth, path)) as File
        let src = recover val String.from_array(file.read(file.size())) end
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
