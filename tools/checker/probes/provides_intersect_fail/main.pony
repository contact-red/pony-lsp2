trait T1
class Bad
class User is (T1 & Bad)

actor Main
  new create(env: Env) => None
