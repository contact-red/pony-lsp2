class Res
  fun dispose() => None

actor Main
  new create(env: Env) =>
    with r = (
      if true then let q: U32 = 1 end
      if true then let q: U32 = 2 end
      Res)
    do
      None
    end
