actor Main
  new create(env: Env) =>
    ifdef (windows; linux) then None end
