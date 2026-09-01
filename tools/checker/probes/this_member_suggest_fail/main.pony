actor Main
  fun _helper(): U8 => 1
  new create(env: Env) =>
    this.helper()
    None
