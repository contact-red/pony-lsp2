actor Main
  new create(env: Env) =>
    if true then
      let a = U8(1)
      env.out.print(a.string())
    end
    let b = a
    None
