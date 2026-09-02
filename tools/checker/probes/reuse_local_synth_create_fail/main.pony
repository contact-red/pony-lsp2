actor Main
  new create(env: Env) => None

primitive Foo
  fun f(): U8 =>
    let create: U8 = 1
    create
