class C
  var other: (C | None) = None
  fun ref f(): (C | None) =>
    consume other
