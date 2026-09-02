actor Main
  new create(env: Env) =>
    let y = U8(1)
    let f = {()(apply = y) => U8(1) }
    None
