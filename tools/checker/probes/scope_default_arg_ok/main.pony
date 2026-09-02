actor Main
  new create(env: Env) => None
  fun g(a: U8 = (let y = U8(1); y)): U8 =>
    let y = U8(2)
    y
