use @f[None](x: U8 = ifdef "d" then U8(1) else U8(2) end) if "linux"

actor Main
  new create(env: Env) =>
    None
