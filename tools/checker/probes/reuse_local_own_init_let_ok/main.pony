actor Main
  new create(env: Env) =>
    let v: U8 =
      recover
        let v = U8(1)
        v
      end
