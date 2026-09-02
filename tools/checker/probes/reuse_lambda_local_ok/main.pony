actor Main
  new create(env: Env) =>
    let x = U8(1)
    let f = {(): U8 =>
      let x = U8(2)
      x
    }
    env.out.print((x + f()).string())
