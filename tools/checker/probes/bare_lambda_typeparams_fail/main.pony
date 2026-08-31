actor Main
  new create(env: Env) =>
    let f = @{[A: Any val](x: U8): U8 => x}
