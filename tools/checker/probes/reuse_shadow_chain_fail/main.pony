actor Main
  new create(env: Env) =>
    let x: U32 = 1
    if true then
      let x: U32 = 2
      if true then
        let x: U32 = 3
        None
      end
    end
    None
