actor Main
  new create(env: Env) =>
    let o = object
      fun helper(): U8 => 1
      fun value(): U8 =>
        let helper = U8(2)
        helper
    end
    None
