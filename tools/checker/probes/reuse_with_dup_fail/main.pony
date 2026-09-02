use "files"

actor Main
  new create(env: Env) =>
    with a = FileLines(File(FilePath(FileAuth(env.root), "x"))),
      b = FileLines(File(FilePath(FileAuth(env.root), "y"))),
      a = FileLines(File(FilePath(FileAuth(env.root), "z")))
    do
      None
    end
