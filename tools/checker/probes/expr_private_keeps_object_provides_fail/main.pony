use d = "./dep"

actor Main
  new create(env: Env) =>
    let x = d._Priv
    let o = object is Other end
    None

class Other
