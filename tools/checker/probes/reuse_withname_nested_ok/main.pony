class Res
  fun dispose() => None

actor Main
  new create(env: Env) =>
    with a = (if true then let b: U32 = 1 end; Res), b = Res do
      None
    end
