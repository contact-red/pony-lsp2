use "./dep"

class Mine is Greeter
  fun greet(): String => greeting()

actor Main
  new create(env: Env) =>
    let s = Shared
    env.out.print(Mine.greet())
