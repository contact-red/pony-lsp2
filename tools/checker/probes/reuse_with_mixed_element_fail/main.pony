class Res
  fun dispose() => None

actor Main
  new create(env: Env) =>
    with a = Res, (a, a) = (Res, Res) do
      None
    end
