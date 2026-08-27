use "itertools"
use "pony_test"
use "../pony_analysis"

primitive \nodoc\ _AnalysisTests is TestList
  fun tag tests(test: PonyTest) =>
    test(_TestOutline)
    test(_TestNesting)
    test(_TestNameSpansPointAtTheName)
    test(_TestFolding)
    test(_TestSingleLineDoesNotFold)
    test(_TestSelectionRanges)
    test(_TestDiagnosticsHaveSpans)
    test(_TestAnswersAboutBrokenSource)
    test(_TestAnswersAboutSourceThatDoesNotCompile)

primitive \nodoc\ _Outline
  fun apply(facts: DocumentFacts): String val =>
    """
    The outline as `kind name` per declaration, indented by nesting, so a
    test asserts on the whole shape at once.
    """
    let out = recover String end
    var i: USize = 0
    for d in facts.declarations.values() do
      if i > 0 then out.append("\n") end
      var container = d.container
      while container isnt None do
        out.append("  ")
        container =
          try
            match container
            | let c: USize => facts.declarations(c)?.container
            else
              None
            end
          else
            None
          end
      end
      out.append(d.kind.name())
      out.append(" ")
      out.append(d.name)
      i = i + 1
    end
    consume out

class \nodoc\ iso _TestOutline is UnitTest
  fun name(): String => "analysis/outline"

  fun apply(h: TestHelper) =>
    let src: String val =
      "primitive Colours\n" +
      "\n" +
      "class Foo\n" +
      "  let x: U32 = 1\n" +
      "  fun f(): U32 => x\n" +
      "  be go() => None\n" +
      "  new create() => None\n" +
      "\n" +
      "actor Bar\n" +
      "type Alias is Foo\n"
    let facts = DocumentFacts(src)
    h.assert_eq[String](
      "primitive Colours\n" +
      "class Foo\n" +
      "  field x\n" +
      "  fun f\n" +
      "  be go\n" +
      "  new create\n" +
      "actor Bar\n" +
      "type Alias",
      _Outline(facts))

class \nodoc\ iso _TestNesting is UnitTest
  fun name(): String => "analysis/members are contained by their entity"

  fun apply(h: TestHelper) =>
    let src: String val =
      "class A\n  fun f() => None\nclass B\n  fun g() => None\n"
    let facts = DocumentFacts(src)
    h.assert_eq[USize](4, facts.declarations.size())
    try
      h.assert_is[(USize | None)](None, facts.declarations(0)?.container)
      h.assert_eq[USize](0, facts.declarations(1)?.container as USize,
        "f is not inside A")
      h.assert_is[(USize | None)](None, facts.declarations(2)?.container)
      h.assert_eq[USize](2, facts.declarations(3)?.container as USize,
        "g is not inside B")
    else
      h.fail("wrong declaration count")
    end

class \nodoc\ iso _TestNameSpansPointAtTheName is UnitTest
  fun name(): String => "analysis/name spans point at the name"

  fun apply(h: TestHelper) =>
    """
    An outline highlights the name and a fold hides the body, so the two
    spans are not interchangeable.
    """
    let src: String val = "class Foo\n  fun bar() => None\n"
    let facts = DocumentFacts(src)
    try
      let entity = facts.declarations(0)?
      h.assert_eq[USize](0, entity.name_span.start_line)
      h.assert_eq[USize](6, entity.name_span.start_character)
      h.assert_eq[USize](9, entity.name_span.finish_character)
      // The whole declaration covers both lines.
      h.assert_eq[USize](0, entity.span.start_line)
      h.assert_true(entity.span.finish_line >= 1)

      let method = facts.declarations(1)?
      h.assert_eq[USize](1, method.name_span.start_line)
      h.assert_eq[USize](6, method.name_span.start_character)
    else
      h.fail("no declarations")
    end

class \nodoc\ iso _TestFolding is UnitTest
  fun name(): String => "analysis/folding"

  fun apply(h: TestHelper) =>
    let src: String val =
      "class Foo\n" +
      "  fun f(): U32 =>\n" +
      "    let a: U32 = 1\n" +
      "    a\n"
    let facts = DocumentFacts(src)
    h.assert_true(_Has(facts, 0, 3), "the class does not fold")
    h.assert_true(_Has(facts, 1, 3), "the method does not fold")

class \nodoc\ iso _TestSingleLineDoesNotFold is UnitTest
  fun name(): String => "analysis/a single line does not fold"

  fun apply(h: TestHelper) =>
    """
    A region that hides nothing is noise in a gutter.
    """
    let facts = DocumentFacts("class Foo\n  fun f() => None\n")
    for region in facts.foldable.values() do
      h.assert_true(region.finish_line > region.start_line,
        "a fold of one line was offered")
    end

class \nodoc\ iso _TestSelectionRanges is UnitTest
  fun name(): String => "analysis/selection ranges"

  fun apply(h: TestHelper) =>
    """
    Expanding a selection walks outwards, and never offers the same
    selection twice.
    """
    let src: String val = "class Foo\n  let x: U32 = 1\n"
    let facts = DocumentFacts(src)
    // On the `x`.
    let spans = facts.enclosing(1, 6)
    h.assert_true(spans.size() > 1, "no chain of spans")

    // Innermost first, each contained by the next, and all distinct.
    var i: USize = 1
    while i < spans.size() do
      try
        let inner = spans(i - 1)?
        let outer = spans(i)?
        h.assert_true(
          (outer.start_line < inner.start_line) or
          ((outer.start_line == inner.start_line) and
            (outer.start_character <= inner.start_character)),
          "span " + i.string() + " does not contain the one before")
        h.assert_false(
          (inner.start_line == outer.start_line) and
          (inner.start_character == outer.start_character) and
          (inner.finish_line == outer.finish_line) and
          (inner.finish_character == outer.finish_character),
          "the same span was offered twice")
      else
        h.fail("bad index")
      end
      i = i + 1
    end

class \nodoc\ iso _TestDiagnosticsHaveSpans is UnitTest
  fun name(): String => "analysis/diagnostics have spans"

  fun apply(h: TestHelper) =>
    let facts = DocumentFacts("class Foo\n  let x = 1\n")
    h.assert_ne[USize](0, facts.diagnostics.size(), "no diagnostic")
    try
      let d = facts.diagnostics(0)?
      h.assert_eq[USize](1, d.span.start_line, "diagnostic on the wrong line")
    else
      h.fail("no diagnostic")
    end

class \nodoc\ iso _TestAnswersAboutBrokenSource is UnitTest
  fun name(): String => "analysis/answers about a source mid-edit"

  fun apply(h: TestHelper) =>
    """
    The point of the whole exercise. Every prefix of a file being typed
    must still yield an outline for what has been written so far, because
    that is the state a buffer is in while someone is working.
    """
    let src: String val =
      "class Foo\n" +
      "  let x: U32 = 1\n" +
      "  fun bar(): U32 =>\n" +
      "    x\n"
    var cut: USize = 0
    var ever_saw_foo = false
    while cut <= src.size() do
      let piece = recover val src.substring(0, cut.isize()) end
      let facts = DocumentFacts(piece)
      // Never fails, whatever the cut.
      for d in facts.declarations.values() do
        if (d.kind is DeclClass) and (d.name == "Foo") then
          ever_saw_foo = true
        end
      end
      cut = cut + 1
    end
    h.assert_true(ever_saw_foo, "never produced the class")

class \nodoc\ iso _TestAnswersAboutSourceThatDoesNotCompile is UnitTest
  fun name(): String => "analysis/answers about source that does not compile"

  fun apply(h: TestHelper) =>
    """
    Nothing here needs a compile, a workspace or anything on disk. A source
    referring to types that do not exist, with a member that is nonsense,
    still has an outline -- which is what pony-lsp cannot do today, because
    a failed whole-program compile leaves it with nothing.
    """
    let src: String val =
      "class Foo is DoesNotExist\n" +
      "  let x: AlsoMissing = undefined_name()\n" +
      "  !!! garbage !!!\n" +
      "  fun still_here(): NopeNotAType => 1\n"
    let facts = DocumentFacts(src)
    h.assert_eq[String](
      "class Foo\n  field x\n  fun still_here",
      _Outline(facts))

primitive \nodoc\ _Has
  fun apply(facts: DocumentFacts, start_line: USize, finish: USize): Bool =>
    for region in facts.foldable.values() do
      if (region.start_line == start_line) and
        (region.finish_line == finish)
      then
        return true
      end
    end
    false
