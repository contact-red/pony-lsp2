use d = "./dep"

actor Main
  new create(env: Env) =>
    let x: d._Priv = d._Priv
