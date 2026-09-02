class Res
  fun dispose() => None

actor Main
  new create(env: Env) =>
    with a = (let b: U32 = 1; Res), b = Res do
      None
    end
