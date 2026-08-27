use "collections"
use "itertools"
use "pony_test"
use "../upstream/tools/lib/ponylang/pony_syntax"

primitive \nodoc\ _TreeTests is TestList
  fun tag tests(test: PonyTest) =>
    test(_TestReprintsTheSource)
    test(_TestShape)
    test(_TestTriviaBelongToTheEnclosingNode)
    test(_TestSubtreeSizesAreConsistent)
    test(_TestWalkOffsetsMatchOffset)
    test(_TestErrorIsBounded)
    test(_TestErrorAtTheStart)
    test(_TestDiagnosticsAreRecorded)
    test(_TestEveryTruncationReprints)
    test(_TestOneRoot)

primitive \nodoc\ _Shape
  fun apply(tree: SyntaxTree val): String val =>
    """
    The tree as nested kind names, so a test can assert on structure in one
    readable string rather than by walking indices.
    """
    let out = recover String end
    for (index, depth, _, kind, _) in tree.walk() do
      if index > 0 then out.append(" ") end
      var d = depth
      while d > 0 do
        out.append(">")
        d = d - 1
      end
      out.append(kind.name())
    end
    consume out

class \nodoc\ iso _TestReprintsTheSource is UnitTest
  fun name(): String => "tree/reprints the source"

  fun apply(h: TestHelper) =>
    """
    Losslessness at the tree level rather than the token level: the leaves
    tile the source, so concatenating them gives it back.
    """
    let sources: Array[String val] = [
      ""
      "use \"collections\""
      "\"\"\"A docstring\"\"\"\nuse \"time\"\n\nclass Foo\n  let x: U32\n"
      "// only a comment\n"
      "class Foo\n\nactor Bar\n\nprimitive Baz\n"
      "use collections = \"collections\"\n"
      "$$$ garbage $$$\n"
      "class Foo\n  fun f() =>\n    /* nested /* comment */ */\n    1\n"
    ]
    for src in sources.values() do
      let tree = Parse(src)
      h.assert_eq[String](src, tree.reprint(),
        "reprint differs for: " + src)
    end

class \nodoc\ iso _TestShape is UnitTest
  fun name(): String => "tree/shape"

  fun apply(h: TestHelper) =>
    h.assert_eq[String](
      "NdModule >NdUse >>TkUse >>TkWhitespace >>TkString >TkEof",
      _Shape(Parse("use \"collections\"")))

class \nodoc\ iso _TestTriviaBelongToTheEnclosingNode is UnitTest
  fun name(): String => "tree/trivia belong to the enclosing node"

  fun apply(h: TestHelper) =>
    """
    Whitespace between two items belongs to what contains them, not to
    whichever item happens to follow. `start` flushes pending trivia before
    it opens a node, which is what puts them there.
    """
    let tree = Parse("class A\n\nclass B\n")
    // The blank line between the two classes is a child of the module, and
    // so is the trailing newline, because an item stops at the token that
    // starts the next one and never consumes the trivia between.
    var module_children: USize = 0
    var kinds = recover String end
    try
      for c in tree.children(0)? do
        module_children = module_children + 1
        kinds.append(tree.kind(c)?.name())
        kinds.append(" ")
      end
    else
      h.fail("no root")
    end
    h.assert_eq[String](
      "NdClassDef TkWhitespace NdClassDef TkWhitespace TkEof ", consume kinds)
    h.assert_eq[USize](5, module_children)
    // And the class does not swallow the blank line after it, which would
    // make its fold range a line too long.
    try
      h.assert_eq[String]("class A", tree.text(1)?)
    else
      h.fail("no first class")
    end

class \nodoc\ iso _TestSubtreeSizesAreConsistent is UnitTest
  fun name(): String => "tree/subtree sizes are consistent"

  fun apply(h: TestHelper) =>
    """
    A node's subtree size must equal one plus the sizes of its children, or
    sibling navigation walks into the middle of a subtree.
    """
    let src = "use \"a\"\nclass Foo\n  fun f() => 1\nactor Bar\n"
    let tree = Parse(src)
    var i: USize = 0
    while i < tree.size() do
      try
        let span = tree.subtree_size(i)?
        var total: USize = 1
        for c in tree.children(i)? do
          total = total + tree.subtree_size(c)?
        end
        h.assert_eq[USize](span, total,
          "element " + i.string() + " (" + tree.kind(i)?.name() + ")")
      else
        h.fail("bad index " + i.string())
      end
      i = i + 1
    end

class \nodoc\ iso _TestWalkOffsetsMatchOffset is UnitTest
  fun name(): String => "tree/walk offsets match offset()"

  fun apply(h: TestHelper) =>
    """
    `walk` accumulates offsets and `offset` recomputes one from scratch.
    They must agree, or a consumer that uses one will disagree with a
    consumer that uses the other.
    """
    let tree = Parse("use \"a\"\n\nclass Foo\n  let x: U32 = 1\n")
    for (index, _, at, _, _) in tree.walk() do
      try
        h.assert_eq[USize](at, tree.offset(index)?,
          "element " + index.string())
      else
        h.fail("no offset for " + index.string())
      end
    end

class \nodoc\ iso _TestErrorIsBounded is UnitTest
  fun name(): String => "tree/an error costs one item"

  fun apply(h: TestHelper) =>
    """
    The point of recovery: a `use` that does not parse must not take the
    class after it with it.
    """
    let src = "use 12345\nclass Foo\n"
    let tree = Parse(src)
    h.assert_eq[String](src, tree.reprint())
    var saw_error = false
    var saw_item = false
    for (_, _, _, kind, _) in tree.walk() do
      if kind is NdError then saw_error = true end
      if kind is NdClassDef then saw_item = true end
    end
    h.assert_true(saw_error, "no error node")
    h.assert_true(saw_item, "the class after the bad use was lost")

class \nodoc\ iso _TestErrorAtTheStart is UnitTest
  fun name(): String => "tree/junk before the first item"

  fun apply(h: TestHelper) =>
    let src = "!!! \nclass Foo\n"
    let tree = Parse(src)
    h.assert_eq[String](src, tree.reprint())
    var saw_item = false
    for (_, _, _, kind, _) in tree.walk() do
      if kind is NdClassDef then saw_item = true end
    end
    h.assert_true(saw_item, "recovery did not reach the class")

class \nodoc\ iso _TestDiagnosticsAreRecorded is UnitTest
  fun name(): String => "tree/diagnostics are recorded"

  fun apply(h: TestHelper) =>
    let tree = Parse("use 12345\n")
    h.assert_ne[USize](0, tree.diagnostics.size(), "no diagnostic")
    try
      let d = tree.diagnostics(0)?
      h.assert_true(d.offset <= "use 12345\n".size(),
        "diagnostic offset out of range")
    else
      h.fail("no diagnostic")
    end

class \nodoc\ iso _TestEveryTruncationReprints is UnitTest
  fun name(): String => "tree/every truncation reprints"

  fun apply(h: TestHelper) =>
    """
    Error tolerance at the tree level, exhaustively: cutting a source at any
    byte must still produce a tree that reprints to it.
    """
    let src =
      "\"\"\"Docstring\"\"\"\n" +
      "use \"collections\"\n" +
      "use c = \"time\"\n" +
      "class Foo\n" +
      "  let x: U32 = 1\n" +
      "actor Bar\n" +
      "  be go() =>\n" +
      "    None\n"
    var cut: USize = 0
    while cut <= src.size() do
      let piece = recover val src.substring(0, cut.isize()) end
      h.assert_eq[String](piece, Parse(piece).reprint(),
        "reprint differs at cut " + cut.string())
      cut = cut + 1
    end

class \nodoc\ iso _TestOneRoot is UnitTest
  fun name(): String => "tree/there is exactly one root"

  fun apply(h: TestHelper) =>
    """
    Element zero must span every element, or the tree has several roots and
    a walk from zero misses part of the source. Trailing trivia emitted
    after the root node was closed is how that happens.
    """
    let sources: Array[String val] = [
      ""
      "class Foo\n"
      "class Foo\n\n\n"
      "use \"a\"\n// trailing comment\n"
      "class A\n\nclass B\n  \n"
      "!!!\n"
      // Leading trivia has nothing to be enclosed by, so it must go inside
      // the root rather than before it.
      "\nclass Foo\n"
      "  \nclass Foo\n"
      "// a leading comment\nclass Foo\n"
      "/* leading */ class Foo\n"
      "\n\n\n"
      "// only a comment"
    ]
    for src in sources.values() do
      let tree = Parse(src)
      try
        h.assert_eq[USize](tree.size(), tree.subtree_size(0)?,
          "root does not span the tree for: " + src)
      else
        h.fail("no root for: " + src)
      end
    end
