class C
  fun f(a: C iso, b: C iso): C iso^ =>
    consume (consume a, consume b)._1
