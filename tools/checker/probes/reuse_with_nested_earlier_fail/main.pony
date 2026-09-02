class Res
  fun dispose() => None

actor Main
  new create(env: Env) =>
    with b = (with q = Res do Res end), b = Res, b = Res do
      None
    end
