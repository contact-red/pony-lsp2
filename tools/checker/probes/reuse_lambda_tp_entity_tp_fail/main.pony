actor Main
  new create(env: Env) => None

class C[A]
  fun f(): U8 =>
    let g = {[A](x: U8): U8 => x }
    1
