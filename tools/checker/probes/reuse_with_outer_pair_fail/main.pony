class Res
  fun dispose() => None

actor Main
  new create(env: Env) =>
    let a: U32 = 1
    with (a, a) = (Res, Res) do
      None
    end
