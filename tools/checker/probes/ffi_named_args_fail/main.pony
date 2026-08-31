use @foo[None](x: U8)
actor Main
  new create(env: Env) =>
    @foo(1 where x = 2)
