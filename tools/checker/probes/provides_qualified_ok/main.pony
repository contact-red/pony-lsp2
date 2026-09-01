use pt = "pony_test"

trait UnitTest
  fun local_only(): U8 => 1

class MyTest is pt.UnitTest
  fun name(): String => "mine"
  fun ref apply(h: pt.TestHelper) =>
    None
  fun use_inherited(): String =>
    label()

actor Main
  new create(env: Env) =>
    None
