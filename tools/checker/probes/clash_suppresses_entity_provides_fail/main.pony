use "./dep1"

actor Main
  new create(env: Env) =>
    None

primitive Mine

class Bad is Mine
