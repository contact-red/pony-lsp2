use "./dep"

primitive _Base

class Mine is Greeter
  fun f(): U8 => hidden()

actor Main
  new create(env: Env) =>
    env.out.print(Mine.f().string())
