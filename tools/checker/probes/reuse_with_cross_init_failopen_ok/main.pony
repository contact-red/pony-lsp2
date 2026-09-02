class Res
  fun dispose() => None

actor Main
  new create(env: Env) =>
    with a = (let q = Res; q), b = (let q = Res; q) do
      None
    end
