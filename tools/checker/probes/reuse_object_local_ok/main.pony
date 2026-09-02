actor Main
  new create(env: Env) =>
    let x = U8(1)
    let o = object
      fun value(): U8 =>
        let x = U8(2)
        x
    end
    env.out.print((x + o.value()).string())
