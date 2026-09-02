class Res
  fun dispose() => None

actor Main
  new create(env: Env) =>
    let b: U32 = 1
    with b = Res, b = Res do
      None
    end
