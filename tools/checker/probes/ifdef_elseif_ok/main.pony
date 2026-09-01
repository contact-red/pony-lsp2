actor Main
  new create(env: Env) =>
    ifdef linux and (not windows) then
      env.out.print("l")
    elseif osx or bsd then
      env.out.print("m")
    elseif freebsd then
      env.out.print("f")
    else
      env.out.print("o")
    end
