primitive P
  fun run(f: {(U32, String)} val) => None

actor Main
  new create(env: Env) =>
    P.run({(_: U32, s: String) => None })
