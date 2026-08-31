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
    test(_TestExpressionShapes)
    test(_TestPostfixNestsToTheLeft)
    test(_TestInfixNestsToTheLeft)
    test(_TestControlStructures)
    test(_TestEveryClauseTakesAnnotations)
    test(_TestJunkInABodyTerminates)
    test(_TestNestingPastTheLimitIsRefused)
    test(_TestRefusalRecoveryResumes)

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

  fun count_within(
    tree: SyntaxTree val,
    parent: NodeKind,
    child: NodeKind)
    : USize
  =>
    """
    Direct children of `child` kind under the first node of `parent` kind.
    """
    for (index, _, _, k, _) in tree.walk() do
      if k is parent then
        var n: USize = 0
        try
          for c in tree.children(index)? do
            if tree.kind(c)? is child then n = n + 1 end
          end
        end
        return n
      end
    end
    0

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
    A `fun` belonging to an `object` literal is that object's member, not
    the end of the enclosing body. The nesting has to survive `iftype` in
    particular: it lexes as TkIftypeSet, and reading it as the other kind
    left every one of them unrecognised.
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
    h.assert_eq[USize](3, _Find.count_within(tree, NdMembers, NdMethod),
      "a nested block ended a body early")
    h.assert_eq[USize](1, _Find.count_within(tree, NdObject, NdMembers),
      "the object literal did not get its own members")

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

class \nodoc\ iso _TestExpressionShapes is UnitTest
  fun name(): String => "grammar/expression shapes"

  fun apply(h: TestHelper) =>
    """
    One expression per case, in a method body, checked by the extent of the
    node it builds. Extents are what hover and selection read, so they are
    what the tests assert on.
    """
    let cases: Array[(String val, NodeKind, String val)] = [
      ("a + b", NdBinOp, "a + b")
      ("a +? b", NdBinOp, "a +? b")
      ("a is b", NdBinOp, "a is b")
      ("a as U32", NdAsOp, "a as U32")
      ("-a", NdUnaryOp, "-a")
      ("not a", NdUnaryOp, "not a")
      ("a = b", NdAssign, "a = b")
      ("let x: U32 = 1", NdLocal, "let x: U32")
      ("f(1, 2)", NdArgs, "(1, 2)")
      ("f(1 where n = 2)", NdNamedArgs, "where n = 2")
      ("[as U32: 1; 2]", NdArray, "[as U32: 1; 2]")
      ("(1, 2)", NdTuple, "1, 2")
      ("@printf[I32](s)?", NdFFICall, "@printf[I32](s)?")
      ("{(x: U32): U32 => x }", NdLambda, "{(x: U32): U32 => x }")
      ("@{(x: U32): U32 => x }", NdBareLambda, "@{(x: U32): U32 => x }")
      ("object fun f() => None end", NdObject, "object fun f() => None end")
      ("consume iso a", NdConsume, "consume iso a")
      ("return", NdJump, "return")
      ("this", NdThis, "this")
      ("__loc", NdLocation, "__loc")
    ]
    for (expr, kind, expected) in cases.values() do
      let src: String val = "class Foo\n  fun f() =>\n    " + expr + "\n"
      let tree = Parse(src)
      _Clean(h, tree, src)
      h.assert_eq[String](expected, _Find.text(h, tree, kind),
        "for: " + expr)
    end

class \nodoc\ iso _TestPostfixNestsToTheLeft is UnitTest
  fun name(): String => "grammar/postfix nests to the left"

  fun apply(h: TestHelper) =>
    """
    Each postfix operator takes everything to its left, so the receiver of
    `.z` is `x.y` and the receiver of the call is `x.y.z`. Without the
    nesting a question about `.y` has no node to be asked of.
    """
    let src: String val = "class Foo\n  fun f() =>\n    x.y.z()?\n"
    let tree = Parse(src)
    _Clean(h, tree, src)
    h.assert_eq[USize](2, _Find.count(tree, NdDot))
    // Pre-order, so the first is the outermost.
    h.assert_eq[String]("x.y.z", _Find.text(h, tree, NdDot))
    h.assert_eq[String]("x.y.z()?", _Find.text(h, tree, NdCall))

class \nodoc\ iso _TestInfixNestsToTheLeft is UnitTest
  fun name(): String => "grammar/infix nests to the left"

  fun apply(h: TestHelper) =>
    """
    Pony gives infix operators no precedence, so each one takes everything
    to its left rather than climbing.
    """
    let src: String val = "class Foo\n  fun f() =>\n    a + b + c\n"
    let tree = Parse(src)
    _Clean(h, tree, src)
    h.assert_eq[USize](2, _Find.count(tree, NdBinOp))
    h.assert_eq[String]("a + b + c", _Find.text(h, tree, NdBinOp))

class \nodoc\ iso _TestControlStructures is UnitTest
  fun name(): String => "grammar/control structures"

  fun apply(h: TestHelper) =>
    """
    Each keyword and the `end` that closes it, which is the extent a client
    folds and the one a selection expands to.
    """
    let cases: Array[(String val, NodeKind)] = [
      ("if a then b else c end", NdIf)
      ("ifdef linux then b else c end", NdIfDef)
      ("iftype A <: B then b else c end", NdIfTypeSet)
      ("match a | b => c else d end", NdMatch)
      ("while a do b else c end", NdWhile)
      ("repeat a until b else c end", NdRepeat)
      ("for x in a do b else c end", NdFor)
      ("with x = a do b end", NdWith)
      ("try a else b then c end", NdTry)
      ("recover val a end", NdRecover)
    ]
    for (expr, kind) in cases.values() do
      let src: String val = "class Foo\n  fun f() =>\n    " + expr + "\n"
      let tree = Parse(src)
      _Clean(h, tree, src)
      h.assert_eq[String](expr, _Find.text(h, tree, kind), "for: " + expr)
    end

class \nodoc\ iso _TestEveryClauseTakesAnnotations is UnitTest
  fun name(): String => "grammar/every clause takes annotations"

  fun apply(h: TestHelper) =>
    """
    ponyc reaches `else`, `then` and the condition after `until` through
    `annotatedseq`, so each of them takes an annotation. Reading them as
    plain sequences left nothing able to consume the backslash, and the
    parser had no way forward.
    """
    let src: String val =
      "class Foo\n" +
      "  fun f() =>\n" +
      "    if \\a\\ p then q else \\a\\ r end\n" +
      "    repeat \\a\\ q until \\a\\ p else \\a\\ r end\n" +
      "    try \\a\\ q else \\a\\ r then \\a\\ s end\n" +
      "    match \\a\\ q | \\a\\ p => r else \\a\\ s end\n"
    let tree = Parse(src)
    _Clean(h, tree, src)
    h.assert_eq[USize](11, _Find.count(tree, NdAnnotations))

class \nodoc\ iso _TestJunkInABodyTerminates is UnitTest
  fun name(): String => "grammar/junk in a body terminates"

  fun apply(h: TestHelper) =>
    """
    A token that starts no expression and ends no sequence would leave the
    sequence rule going around without consuming anything. No input may
    hang the parser, so the loop takes such a token as an error instead.
    """
    let src: String val = "class Foo\n  fun f() =>\n    ?? ]] => a\n"
    let tree = Parse(src)
    h.assert_eq[String](src, tree.reprint(), "reprint differs")
    h.assert_ne[USize](0, tree.diagnostics.size(), "no diagnostic")
    h.assert_eq[USize](1, _Find.count(tree, NdMethod),
      "the method was lost")

class \nodoc\ iso _TestNestingPastTheLimitIsRefused is UnitTest
  fun name(): String => "grammar/nesting past the limit is refused"

  fun apply(h: TestHelper) =>
    """
    Each recursion shape at its exact boundary, both legs: the deepest
    depth the guard admits parses clean, one more is refused with the
    guard's own diagnostic, and the tree still reprints byte for byte.
    The boundaries pin `_MaxNesting` at 500: parentheses descend
    through both the sequence rule and the term rule, two per source
    level, so they meet the limit at 249; the other shapes descend
    once per level, on top of the constant descents of their
    enclosing declaration. Each shape exercises a different guarded
    cycle — term, prefix, type, assignment, for-pattern, constant
    expression — so a boundary that moves means a guard was added,
    removed, or the limit changed. Far past the limit every shape
    must refuse with a diagnostic rather than crash, which the deep
    legs check.
    """
    _check(h, "paren", _Nested.parens(249), _Nested.parens(250))
    _check(h, "prefix", _Nested.prefixes(498), _Nested.prefixes(499))
    _check(h, "type", _Nested.types(499), _Nested.types(500))
    _check(h, "assign", _Nested.assigns(498), _Nested.assigns(499))
    _check(h, "idseq",
      _Nested.for_patterns(498), _Nested.for_patterns(499))
    _check(h, "constexpr",
      _Nested.const_exprs(496), _Nested.const_exprs(497))
    _check_deep(h, "paren", _Nested.parens(20_000))
    _check_deep(h, "assign", _Nested.assigns(20_000))
    _check_deep(h, "idseq", _Nested.for_patterns(20_000))
    _check_deep(h, "constexpr", _Nested.const_exprs(20_000))

  fun _check(
    h: TestHelper,
    shape: String,
    admitted: String val,
    refused: String val)
  =>
    let ok = Parse(admitted)
    h.assert_eq[String](admitted, ok.reprint(),
      shape + ": admitted reprint differs")
    h.assert_eq[USize](0, ok.diagnostics.size(),
      shape + ": the guard fired under the limit")

    let bad = Parse(refused)
    h.assert_eq[String](refused, bad.reprint(),
      shape + ": refused reprint differs")
    h.assert_ne[USize](0, bad.diagnostics.size(),
      shape + ": the guard did not fire past the limit")
    var found = false
    for d in bad.diagnostics.values() do
      if d.message.contains("grammar depth limit") then
        found = true
      end
    end
    h.assert_true(found,
      shape + ": no diagnostic names the depth limit")

  fun _check_deep(h: TestHelper, shape: String, refused: String val) =>
    let tree = Parse(refused)
    h.assert_eq[String](refused, tree.reprint(),
      shape + ": deep reprint differs")
    h.assert_ne[USize](0, tree.diagnostics.size(),
      shape + ": the guard did not fire far past the limit")

class \nodoc\ iso _TestRefusalRecoveryResumes is UnitTest
  fun name(): String => "grammar/depth refusal keeps the rest of the file"

  fun apply(h: TestHelper) =>
    """
    Refusing an over-deep region must not cost the declarations after
    it: recovery resynchronises to a closing token, so the entity that
    follows the refused one still parses.
    """
    let src: String val =
      recover val
        let out = String
        out.append(_Nested.parens(300))
        out.append("class After\n  fun f(): U8 => 0\n")
        out
      end
    let tree = Parse(src)
    h.assert_eq[String](src, tree.reprint(), "reprint differs")
    h.assert_ne[USize](0, tree.diagnostics.size(), "the guard did not fire")
    var entities: USize = 0
    for (_, _, _, kind, _) in tree.walk() do
      if kind is NdClassDef then
        entities = entities + 1
      end
    end
    h.assert_eq[USize](2, entities,
      "the declaration after the refused region was lost")

primitive \nodoc\ _Nested
  fun parens(depth: USize): String val =>
    _body(recover val "(".mul(depth) + "1" + ")".mul(depth) end)

  fun prefixes(depth: USize): String val =>
    _body(recover val "not ".mul(depth) + "true" end)

  fun types(depth: USize): String val =>
    recover val
      let out = String((depth * 3) + 16)
      out.append("type T is ")
      out.append("A[".mul(depth))
      out.append("U8")
      out.append("]".mul(depth))
      out.push('\n')
      out
    end

  fun assigns(depth: USize): String val =>
    recover val
      let out = String((depth * 4) + 80)
      out.append("actor Main\n  new create(env: Env) =>\n")
      out.append("    var x: U64 = 0\n    ")
      var i: USize = 0
      while i < depth do
        out.append("x = ")
        i = i + 1
      end
      out.append("1\n")
      out
    end

  fun for_patterns(depth: USize): String val =>
    recover val
      let out = String((depth * 2) + 120)
      out.append("actor Main\n  new create(env: Env) =>\n    None\n")
      out.append("  fun f(b: Array[U8]): None =>\n    for ")
      out.append("(".mul(depth))
      out.push('a')
      out.append(")".mul(depth))
      out.append(" in b do None end\n")
      out
    end

  fun const_exprs(depth: USize): String val =>
    recover val
      let out = String((depth * 4) + 120)
      out.append("class F[A: Any val]\nactor Main\n")
      out.append("  new create(env: Env) =>\n    let x = F[")
      out.append("#F[".mul(depth))
      out.append("U8")
      out.append("]".mul(depth + 1))
      out.push('\n')
      out
    end

  fun _body(expr: String val): String val =>
    recover val
      let out = String(expr.size() + 64)
      out.append("actor Main\n  new create(env: Env) =>\n    ")
      out.append(expr)
      out.push('\n')
      out
    end
