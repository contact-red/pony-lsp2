actor Main
  new create(env: Env) => None

class C[A]
  fun f(): U8 =>
    let o = object
      fun g[A](x: U8): U8 => x
    end
    1
