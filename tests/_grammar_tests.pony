use "collections"
use "pony_test"
use "../upstream/tools/lib/ponylang/pony_syntax"

primitive \nodoc\ _GrammarTests is TestList
  fun tag tests(test: PonyTest) =>
    test(_TestEntityExtents)
    test(_TestTypeGrammar)
    test(_TestUseForms)
    test(_TestMethodBodyKeepsItsLocals)
    test(_TestNestedBlocksInABody)
    test(_TestBadMemberCostsOneMember)
    test(_TestBadEntityCostsOneEntity)
    test(_TestMissingFieldTypeIsReported)

primitive \nodoc\ _Find
  fun text(h: TestHelper, tree: SyntaxTree val, kind: NodeKind)
    : String val
  =>
    """
    The source text of the first node of `kind`, or "" with a failure.
    """
    for (index, _, _, k, _) in tree.walk() do
      if k is kind then
        try
          return recover val tree.text(index)? end
        end
      end
    end
    h.fail("no " + kind.name() + " in the tree")
    ""

  fun count(tree: SyntaxTree val, kind: NodeKind): USize =>
    var n: USize = 0
    for (_, _, _, k, _) in tree.walk() do
      if k is kind then n = n + 1 end
    end
    n

primitive \nodoc\ _Clean
  fun apply(h: TestHelper, tree: SyntaxTree val, src: String val) =>
    """
    A source that should parse without complaint, and always losslessly.
    """
    h.assert_eq[String](src, tree.reprint(), "reprint differs")
    if tree.diagnostics.size() > 0 then
      try
        h.fail("unexpected diagnostic: " + tree.diagnostics(0)?.string())
      end
    end

class \nodoc\ iso _TestEntityExtents is UnitTest
  fun name(): String => "grammar/entity extents"

  fun apply(h: TestHelper) =>
    """
    Extents are what an outline and folding read, so they are what the
    tests assert on.
    """
    let src: String val =
      "class Foo[A: Any val] is Bar\n" +
      "  \"\"\"Docs\"\"\"\n" +
      "  let x: U32 = 1\n" +
      "  fun f(): U32 => x\n"
    let tree = Parse(src)
    _Clean(h, tree, src)
    h.assert_eq[String]("[A: Any val]",
      _Find.text(h, tree, NdTypeParams))
    h.assert_eq[String]("is Bar", _Find.text(h, tree, NdProvides))
    h.assert_eq[String]("let x: U32 = 1", _Find.text(h, tree, NdField))
    h.assert_eq[String]("fun f(): U32 => x", _Find.text(h, tree, NdMethod))

class \nodoc\ iso _TestTypeGrammar is UnitTest
  fun name(): String => "grammar/type grammar"

  fun apply(h: TestHelper) =>
    """
    A union, an intersection, a tuple, a viewpoint and a lambda type, each
    as the declared type of a field so that the extent is checkable.
    """
    let cases: Array[(String val, String val)] = [
      ("(U32 | None)", "(U32 | None)")
      ("(Reader & Writer)", "(Reader & Writer)")
      ("(U32, String)", "(U32, String)")
      ("this->Array[U8]", "this->Array[U8]")
      ("{(U32): String} val", "{(U32): String} val")
      ("Map[String, U32] box", "Map[String, U32] box")
      ("A.B[C] iso^", "A.B[C] iso^")
    ]
    for (declared, expected) in cases.values() do
      let src: String val = "class Foo\n  let x: " + declared + "\n"
      let tree = Parse(src)
      _Clean(h, tree, src)
      h.assert_eq[String]("let x: " + expected,
        _Find.text(h, tree, NdField), "for type " + declared)
    end

class \nodoc\ iso _TestUseForms is UnitTest
  fun name(): String => "grammar/use forms"

  fun apply(h: TestHelper) =>
    let cases: Array[String val] = [
      "use \"collections\"\n"
      "use c = \"collections\"\n"
      "use @memcmp[I32](a: Pointer[None] tag, b: Pointer[None] tag)\n"
      "use \"collections\" if linux\n"
      "use @exit[None](code: I32) if not windows\n"
    ]
    for src in cases.values() do
      let tree = Parse(src)
      _Clean(h, tree, src)
      h.assert_eq[USize](1, _Find.count(tree, NdUse), "for: " + src)
    end

class \nodoc\ iso _TestMethodBodyKeepsItsLocals is UnitTest
  fun name(): String => "grammar/a body keeps its locals"

  fun apply(h: TestHelper) =>
    """
    A body is full of `let` and `var`, so those cannot end one. Treating
    them as member starts ended every body at its first local and left the
    rest to be read as fields -- 115 of the 255 standard library files.
    """
    let src: String val =
      "class Foo\n" +
      "  fun f(): U32 =>\n" +
      "    let a: U32 = 1\n" +
      "    var b = a + 1\n" +
      "    b\n" +
      "  fun g(): U32 => 2\n"
    let tree = Parse(src)
    _Clean(h, tree, src)
    h.assert_eq[USize](2, _Find.count(tree, NdMethod))
    h.assert_eq[USize](0, _Find.count(tree, NdField),
      "a local was read as a field")

class \nodoc\ iso _TestNestedBlocksInABody is UnitTest
  fun name(): String => "grammar/nested blocks in a body"

  fun apply(h: TestHelper) =>
    """
    The skeleton tracks the regions Pony closes with `end`, so that a
    method's body does not end at a `fun` belonging to an `object` literal,
    and an `iftype` is counted -- it lexes as TkIftypeSet, and using the
    other kind left every one of them uncounted.
    """
    let src: String val =
      "class Foo\n" +
      "  fun f[A: Any val](): U32 =>\n" +
      "    iftype A <: U32 then\n" +
      "      ifdef ilp32 then\n" +
      "        1\n" +
      "      else\n" +
      "        2\n" +
      "      end\n" +
      "    else\n" +
      "      3\n" +
      "    end\n" +
      "  fun g(): Any =>\n" +
      "    object\n" +
      "      fun apply(): U32 => 1\n" +
      "    end\n" +
      "  fun h(): U32 => 4\n"
    let tree = Parse(src)
    _Clean(h, tree, src)
    h.assert_eq[USize](3, _Find.count(tree, NdMethod),
      "a nested block ended a body early")

class \nodoc\ iso _TestBadMemberCostsOneMember is UnitTest
  fun name(): String => "grammar/a bad member costs one member"

  fun apply(h: TestHelper) =>
    let src: String val =
      "class Foo\n" +
      "  !!! nonsense !!!\n" +
      "  fun f(): U32 => 1\n"
    let tree = Parse(src)
    h.assert_eq[String](src, tree.reprint())
    h.assert_eq[USize](1, _Find.count(tree, NdClassDef))
    h.assert_eq[USize](1, _Find.count(tree, NdMethod),
      "the method after the bad member was lost")

class \nodoc\ iso _TestBadEntityCostsOneEntity is UnitTest
  fun name(): String => "grammar/a bad entity costs one entity"

  fun apply(h: TestHelper) =>
    """
    ponyc's RESTART set is the top-level keywords, which is what bounds an
    error to the item it is in.
    """
    let src: String val =
      "class 123\n" +
      "actor Good\n" +
      "  be go() => None\n"
    let tree = Parse(src)
    h.assert_eq[String](src, tree.reprint())
    h.assert_eq[USize](2, _Find.count(tree, NdClassDef))
    h.assert_eq[USize](1, _Find.count(tree, NdMethod),
      "the actor after the bad class was lost")

class \nodoc\ iso _TestMissingFieldTypeIsReported is UnitTest
  fun name(): String => "grammar/a field must declare a type"

  fun apply(h: TestHelper) =>
    """
    ponyc requires it, and the diagnostic is what a language server shows.
    """
    let src: String val = "class Foo\n  let x = 1\n"
    let tree = Parse(src)
    h.assert_eq[String](src, tree.reprint())
    h.assert_ne[USize](0, tree.diagnostics.size(), "no diagnostic")
