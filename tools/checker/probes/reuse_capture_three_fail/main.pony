actor Main
  new create(env: Env) =>
    let y: U32 = 1
    let g = {()(a = y, a = y, a = y): U32 => a }
    None
