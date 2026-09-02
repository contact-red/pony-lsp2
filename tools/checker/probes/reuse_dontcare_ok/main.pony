actor Main
  new create(env: Env) =>
    (let a, _) = (U8(1), U8(2))
    (let b, _) = (U8(3), U8(4))
    _ = a + b
    None
