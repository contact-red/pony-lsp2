actor Main
  new create(env: Env) => None

class C
  new make() => None
  fun f(): U8 =>
    let create: U8 = 1
    create
