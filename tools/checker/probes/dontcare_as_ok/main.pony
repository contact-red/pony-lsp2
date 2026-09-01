actor Main
  new create(env: Env) =>
    let t: (String, (U8 | String)) = ("one", U8(1))
    try
      let n = t as (_, U8)
      env.out.print(n.string())
    end
