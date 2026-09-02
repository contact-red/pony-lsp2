actor Main
  new create(env: Env) =>
    let o = object
      new create() => None
      fun apply(): U8 => 1
    end
    None
