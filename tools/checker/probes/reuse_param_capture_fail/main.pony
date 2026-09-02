actor Main
  new create(env: Env) =>
    let y = U8(1)
    let f = {(x: U8)(x = y): U8 => x }
    None
