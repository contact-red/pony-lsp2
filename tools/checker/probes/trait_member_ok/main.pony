trait Helper
  fun helper(): U8 => 1
actor Main is Helper
  new create(env: Env) =>
    let x = helper()
