actor Main
  new create(env: Env) =>
    let y = U8(1)
    let f = {()(create = y) => U8(1) }
    None
