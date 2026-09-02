use d = "./dep"

actor Main
  new create(env: Env) =>
    let x: d._Priv = None
    None

class Other

class Bad is Other
