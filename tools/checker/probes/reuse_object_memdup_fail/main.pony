actor Main
  new create(env: Env) =>
    let o = object
      fun g(): U8 => 1
      fun g(): U8 => 2
    end
    None
