actor Main
  new create(env: Env) =>
    ifdef \myann\ linux then
      env.out.print("l")
    end
