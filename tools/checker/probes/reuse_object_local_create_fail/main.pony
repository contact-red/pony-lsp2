actor Main
  new create(env: Env) =>
    let o = object
      let x: U8 = 1
      fun f(): U8 =>
        let create: U8 = 2
        create
    end
    None
