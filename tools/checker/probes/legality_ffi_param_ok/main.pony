use @pony_exitcode[None](Code: I32)

actor Main
  new create(env: Env) =>
    @pony_exitcode(0)
