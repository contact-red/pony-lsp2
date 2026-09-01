actor Main
  new create(env: Env) =>
    let outer = U8(1)
    let f = {()(q = outer): U8 => q}
    env.out.print(f().string())
