actor Main
  new create(env: Env) => None

trait B

class C
  fun f(): U8 =>
    let g = {[B](x: U8): U8 => x }
    1
