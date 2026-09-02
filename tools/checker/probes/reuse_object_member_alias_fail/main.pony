use coll = "collections"

actor Main
  new create(env: Env) =>
    let o = object
      fun coll(): U8 => 1
    end
    None
