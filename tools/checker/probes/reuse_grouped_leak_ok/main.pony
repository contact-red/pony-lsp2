actor Main
  new create(env: Env) =>
    let y = (let x = U8(1); x + U8(0))
    env.out.print(x.string())
