actor Main
  new create(env: Env) =>
    let x = U8(1)
    if true then
      let x = U8(2)
      None
    end
