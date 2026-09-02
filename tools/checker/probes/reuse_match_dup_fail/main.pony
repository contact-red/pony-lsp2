actor Main
  new create(env: Env) =>
    match (U8(1), U8(2))
    | (let a: U8, let a: U8) => None
    end
