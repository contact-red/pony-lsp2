actor Main
  new create(env: Env) =>
    let t: (String, (U8 | String)) = ("one", U8(1))
    try
      let a = t as ((_, U8))
      let b = t as (((_), U8))
      env.out.print((a + b).string())
    end
