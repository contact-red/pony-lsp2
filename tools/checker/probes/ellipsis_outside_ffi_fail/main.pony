use @foo[None](x: Any tag)
actor Main
  new create(env: Env) =>
    @foo(object fun f(a: U8, ...) => None end)
