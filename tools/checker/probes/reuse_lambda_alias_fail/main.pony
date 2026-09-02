use col = "collections"

actor Main
  new create(env: Env) =>
    let f = {(col: U8): U8 => col }
    None
