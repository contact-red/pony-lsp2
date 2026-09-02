use "pony_test"
use "../upstream/tools/lib/ponylang/pony_analysis"
use "../upstream/tools/lib/ponylang/pony_bind"

primitive \nodoc\ _ScopeTests is TestList
  fun tag tests(test: PonyTest) =>
    test(_TestResolvesAParameter)
    test(_TestResolvesAField)
    test(_TestResolvesATypeParameter)
    test(_TestAnInnerLocalShadows)
    test(_TestALocalIsNotVisibleAfterItsBlock)
    test(_TestALocalIsNotVisibleBeforeItsDeclaration)
    test(_TestAForNameDoesNotCaptureItsIterator)
    test(_TestResolvesALambdaParameter)
    test(_TestResolvesAMatchPattern)
    test(_TestResolvesATuplePatternCaptureInTheBody)
    test(_TestAGroupedLocalIsVisibleAfterItsGroup)
    test(_TestADestructuredLocalIsVisibleAfterItsStatement)
    test(_TestACaptureIsNotVisibleInALaterCase)
    test(_TestACaptureIsNotVisibleAfterItsMatch)
    test(_TestAGroupedLocalIsNotVisibleAfterItsBlock)
    test(_TestAWithLocalIsNotVisibleAfterItsWith)
    test(_TestADefaultArgLocalIsNotVisibleInTheBody)
    test(_TestALocalShadowsAType)
    test(_TestFallsThroughToTheWorkspace)
    test(_TestFFIParametersAreScopedToTheirDeclaration)

primitive \nodoc\ _Cursor
  """
  Where a substring is, as a client would say it.
  """
  fun apply(source: String val, needle: String val, nth: USize = 0)
    : (USize, USize)
  =>
    var from: ISize = 0
    var seen: USize = 0
    var found: USize = 0
    while true do
      let at =
        try
          source.find(needle, from)?
        else
          return (0, 0)
        end
      if seen == nth then
        found = at.usize()
        break
      end
      seen = seen + 1
      from = at + 1
    end

    var line: USize = 0
    var start: USize = 0
    var i: USize = 0
    while i < found do
      if try source(i)? == '\n' else false end then
        line = line + 1
        start = i + 1
      end
      i = i + 1
    end
    (line, found - start)

primitive \nodoc\ _Bound
  """
  A one-file workspace holding `source`, ready to be asked about.
  """
  fun apply(source: String val): Binder =>
    let binder = Binder
    binder.set_source("/w/app/main.pony", source)
    binder.set_files("/w/app", ["/w/app/main.pony"])
    binder

primitive \nodoc\ _Expect
  fun unbound(
    h: TestHelper,
    binder: Binder ref,
    source: String val,
    needle: String val,
    nth: USize,
    why: String val)
  =>
    """
    The occurrence must exist and must resolve to nothing — a missed
    needle would land the cursor at 0:0 and pass vacuously.
    """
    try
      source.find(needle where nth = nth)?
    else
      h.fail(why + ": the source has no such occurrence")
      return
    end
    (let line, let character) = _Cursor(source, needle, nth)
    match binder.resolve_at("/w/app/main.pony", line, character)
    | let _: Binding =>
      h.fail(why)
    | let _: BoundItem =>
      h.fail(why + ": resolved to a workspace declaration")
    end

  fun binding(
    h: TestHelper,
    binder: Binder ref,
    source: String val,
    needle: String val,
    nth: USize,
    kind: BindingKind,
    declared_on: USize,
    why: String val)
  =>
    (let line, let character) = _Cursor(source, needle, nth)
    match binder.resolve_at("/w/app/main.pony", line, character)
    | let bound: Binding =>
      h.assert_eq[String](needle, bound.name, why + ": name")
      h.assert_is[BindingKind](kind, bound.kind, why + ": kind")
      h.assert_eq[USize](
        declared_on, bound.name_span.start_line, why + ": declared on")
    | let item: BoundItem =>
      h.fail(why + ": resolved to a workspace declaration, " + item.name())
    else
      h.fail(why + ": resolved to nothing")
    end

class \nodoc\ iso _TestResolvesAParameter is UnitTest
  fun name(): String => "scope/resolves a parameter"

  fun apply(h: TestHelper) =>
    let source: String val =
      "class Foo\n" +
      "  fun f(p: U32): U32 =>\n" +
      "    p\n"
    _Expect.binding(h, _Bound(source), source, "p", 1, BindParam, 1,
      "the use of p")

class \nodoc\ iso _TestResolvesAField is UnitTest
  fun name(): String => "scope/resolves a field"

  fun apply(h: TestHelper) =>
    """
    A field is visible throughout its entity.

    The field has to be written before the method, and not because of
    scoping: a `let` after a method body is part of that body, which is how
    ponyc reads it too.
    """
    let source: String val =
      "class Foo\n" +
      "  let counter: U32 = 0\n" +
      "  fun f(): U32 =>\n" +
      "    counter\n"
    _Expect.binding(h, _Bound(source), source, "counter", 1, BindField, 1,
      "a field used from a method")

class \nodoc\ iso _TestResolvesATypeParameter is UnitTest
  fun name(): String => "scope/resolves a type parameter in its signature"

  fun apply(h: TestHelper) =>
    """
    A method's type parameters are visible in its own signature, which is
    why where a binding becomes visible is not simply where its scope
    starts.
    """
    let source: String val =
      "class Foo\n" +
      "  fun f[A: Any val](x: A): A =>\n" +
      "    x\n"
    _Expect.binding(h, _Bound(source), source, "A", 2, BindTypeParam, 1,
      "the parameter's type")

class \nodoc\ iso _TestAnInnerLocalShadows is UnitTest
  fun name(): String => "scope/an inner local shadows an outer one"

  fun apply(h: TestHelper) =>
    let source: String val =
      "class Foo\n" +
      "  fun f(): U32 =>\n" +
      "    var x: U32 = 1\n" +
      "    if true then\n" +
      "      var x: U32 = 2\n" +
      "      x\n" +
      "    end\n" +
      "    x\n"
    let binder = _Bound(source)
    _Expect.binding(h, binder, source, "x", 2, BindLocal, 4,
      "the use inside the block")
    _Expect.binding(h, binder, source, "x", 3, BindLocal, 2,
      "the use after the block")

class \nodoc\ iso _TestALocalIsNotVisibleAfterItsBlock is UnitTest
  fun name(): String => "scope/a local is not visible after its block"

  fun apply(h: TestHelper) =>
    let source: String val =
      "class Foo\n" +
      "  fun f(): U32 =>\n" +
      "    if true then\n" +
      "      var inner: U32 = 1\n" +
      "    end\n" +
      "    inner\n"
    let binder = _Bound(source)
    (let line, let character) = _Cursor(source, "inner", 1)
    match binder.resolve_at("/w/app/main.pony", line, character)
    | let bound: Binding =>
      h.fail("a local escaped its block")
    end

class \nodoc\ iso _TestALocalIsNotVisibleBeforeItsDeclaration is UnitTest
  fun name(): String => "scope/a local is not visible before it is declared"

  fun apply(h: TestHelper) =>
    """
    Pony rejects a use before the declaration, so resolving one would name
    a binding the compiler will not.
    """
    let source: String val =
      "class Foo\n" +
      "  fun f(): U32 =>\n" +
      "    later\n" +
      "    var later: U32 = 1\n"
    let binder = _Bound(source)
    (let line, let character) = _Cursor(source, "later", 0)
    match binder.resolve_at("/w/app/main.pony", line, character)
    | let bound: Binding =>
      h.fail("a local resolved above its own declaration")
    end

class \nodoc\ iso _TestAForNameDoesNotCaptureItsIterator is UnitTest
  fun name(): String => "scope/a for name does not capture its iterator"

  fun apply(h: TestHelper) =>
    """
    In `for x in x.next()` the second `x` is the outer one: the loop
    variable does not exist until the body. ponyc gets this from the
    desugaring, which puts the iterator outside the scope; here it comes
    from the loop's bindings not being visible until `do`.
    """
    let source: String val =
      "class Foo\n" +
      "  fun f() =>\n" +
      "    var x: U32 = 1\n" +
      "    for x in x.values() do\n" +
      "      x\n" +
      "    end\n"
    let binder = _Bound(source)
    _Expect.binding(h, binder, source, "x", 2, BindLocal, 2,
      "the iterator expression")
    _Expect.binding(h, binder, source, "x", 3, BindLocal, 3,
      "the loop body")

class \nodoc\ iso _TestResolvesALambdaParameter is UnitTest
  fun name(): String => "scope/resolves a lambda parameter"

  fun apply(h: TestHelper) =>
    let source: String val =
      "class Foo\n" +
      "  fun f() =>\n" +
      "    {(n: U32): U32 => n }\n"
    // "fun" holds an n, so the parameter is the second and its use the
    // third.
    _Expect.binding(h, _Bound(source), source, "n", 2, BindParam, 2,
      "the lambda body")
    _Expect.binding(h, _Bound(source), source, "n", 1, BindParam, 2,
      "the parameter's own name")

class \nodoc\ iso _TestResolvesAMatchPattern is UnitTest
  fun name(): String => "scope/resolves a match pattern binding"

  fun apply(h: TestHelper) =>
    let source: String val =
      "class Foo\n" +
      "  fun f(v: Any) =>\n" +
      "    match v\n" +
      "    | let got: U32 => got\n" +
      "    end\n"
    _Expect.binding(h, _Bound(source), source, "got", 1, BindLocal, 3,
      "the case body")



class \nodoc\ iso _TestALocalShadowsAType is UnitTest
  fun name(): String => "scope/a local shadows a type of the same name"

  fun apply(h: TestHelper) =>
    """
    The document is asked before the workspace, because a name bound here
    is what the name means here.
    """
    let source: String val =
      "class Helper\n" +
      "class Foo\n" +
      "  fun f() =>\n" +
      "    var Helper: U32 = 1\n" +
      "    Helper\n"
    _Expect.binding(h, _Bound(source), source, "Helper", 2, BindLocal, 3,
      "the use after the local")

class \nodoc\ iso _TestFallsThroughToTheWorkspace is UnitTest
  fun name(): String => "scope/an unbound name falls through to the workspace"

  fun apply(h: TestHelper) =>
    let source: String val =
      "class Foo\n" +
      "  fun f(): Helper =>\n" +
      "    x\n"
    let binder = _Bound(source)
    binder.set_source("/w/app/helper.pony", "class Helper\n")
    binder.set_files(
      "/w/app", ["/w/app/main.pony"; "/w/app/helper.pony"])

    (let line, let character) = _Cursor(source, "Helper", 0)
    match binder.resolve_at("/w/app/main.pony", line, character)
    | let item: BoundItem =>
      h.assert_eq[String]("/w/app/helper.pony", item.file)
      match binder.declared_at(item)
      | let location: Span =>
        h.assert_eq[USize](0, location.start_line, "Helper is declared on line 0")
      else
        h.fail("no span for the declaration")
      end
    | let bound: Binding =>
      h.fail("a type resolved to a local binding")
    else
      h.fail("Helper did not resolve")
    end

class \nodoc\ iso _TestFFIParametersAreScopedToTheirDeclaration is UnitTest
  fun name(): String => "scope/an FFI parameter is scoped to its declaration"

  fun apply(h: TestHelper) =>
    """
    ponyc puts a scope on `use_ffi`, and an FFI declaration does not look
    like one. `net/tcp_connection.pony` declares thirty
    `use @pony_asio_event_*` with a parameter named `event`; without a
    scope each they are all visible over the whole file and every one of
    them resolves to the first.
    """
    let source: String val =
      "use @first[None](event: U32)\n" +
      "use @second[None](event: U32)\n" +
      "class Foo\n"
    _Expect.binding(h, _Bound(source), source, "event", 1, BindParam, 1,
      "the second declaration's parameter")

class \nodoc\ iso _TestResolvesATuplePatternCaptureInTheBody
  is UnitTest
  fun name(): String =>
    "scope/resolves a tuple pattern capture in the body"

  fun apply(h: TestHelper) =>
    """
    A capture in a tuple pattern lands in the case's scope, not the
    sequence the tuple element wraps it in, so a use in the body
    resolves to it.
    """
    let source: String val =
      "class Foo\n" +
      "  fun f(): U32 =>\n" +
      "    match (U32(1), U32(2))\n" +
      "    | (let left: U32, let rest: U32) => left + rest\n" +
      "    else\n" +
      "      0\n" +
      "    end\n"
    _Expect.binding(h, _Bound(source), source, "left", 1, BindLocal, 3,
      "the arm body")

class \nodoc\ iso _TestAGroupedLocalIsVisibleAfterItsGroup is UnitTest
  fun name(): String => "scope/a grouped local is visible after its group"

  fun apply(h: TestHelper) =>
    """
    ponyc's paren rule opens no scope, so a local declared inside a
    parenthesised sequence outlives the closing paren.
    """
    let source: String val =
      "class Foo\n" +
      "  fun f(): U32 =>\n" +
      "    let y = (let x: U32 = 1; x + 0)\n" +
      "    x\n"
    _Expect.binding(h, _Bound(source), source, "x", 2, BindLocal, 2,
      "after the group")

class \nodoc\ iso _TestADestructuredLocalIsVisibleAfterItsStatement
  is UnitTest
  fun name(): String =>
    "scope/a destructured local is visible after its statement"

  fun apply(h: TestHelper) =>
    """
    ponyc's tuple-assignment sugar rewrites each element into the
    enclosing block, so the names outlive the pattern's own sequences.
    """
    let source: String val =
      "class Foo\n" +
      "  fun f(): U32 =>\n" +
      "    (let left: U32, let rest: U32) = (U32(1), U32(2))\n" +
      "    left + rest\n"
    _Expect.binding(h, _Bound(source), source, "left", 1, BindLocal, 2,
      "after the destructuring statement")

class \nodoc\ iso _TestACaptureIsNotVisibleInALaterCase is UnitTest
  fun name(): String => "scope/a capture is not visible in a later case"

  fun apply(h: TestHelper) =>
    let source: String val =
      "class Foo\n" +
      "  fun f(): U32 =>\n" +
      "    match U32(1)\n" +
      "    | let seen: U32 if seen > 2 => seen\n" +
      "    | U32(0) => seen\n" +
      "    else\n" +
      "      0\n" +
      "    end\n"
    let binder = _Bound(source)
    _Expect.binding(h, binder, source, "seen", 1, BindLocal, 3,
      "the capture's own guard")
    _Expect.unbound(h, binder, source, "seen", 3,
      "a capture escaped its case")

class \nodoc\ iso _TestACaptureIsNotVisibleAfterItsMatch is UnitTest
  fun name(): String => "scope/a capture is not visible after its match"

  fun apply(h: TestHelper) =>
    let source: String val =
      "class Foo\n" +
      "  fun f(): U32 =>\n" +
      "    match U32(1)\n" +
      "    | let seen: U32 => seen\n" +
      "    else\n" +
      "      0\n" +
      "    end\n" +
      "    seen\n"
    let binder = _Bound(source)
    _Expect.binding(h, binder, source, "seen", 1, BindLocal, 3,
      "the arm body")
    _Expect.unbound(h, binder, source, "seen", 2,
      "a capture escaped its match")

class \nodoc\ iso _TestAGroupedLocalIsNotVisibleAfterItsBlock
  is UnitTest
  fun name(): String =>
    "scope/a grouped local is not visible after its block"

  fun apply(h: TestHelper) =>
    """
    A group's sequence is transparent, so the local lands in the
    enclosing block's scope — and no further: it still dies with
    that block.
    """
    let source: String val =
      "class Foo\n" +
      "  fun f(): U32 =>\n" +
      "    if true then\n" +
      "      let y = (let inner: U32 = 1; inner + 0)\n" +
      "    end\n" +
      "    inner\n"
    let binder = _Bound(source)
    _Expect.binding(h, binder, source, "inner", 1, BindLocal, 3,
      "inside the group's own statement")
    _Expect.unbound(h, binder, source, "inner", 2,
      "a grouped local escaped its enclosing block")

class \nodoc\ iso _TestAWithLocalIsNotVisibleAfterItsWith
  is UnitTest
  fun name(): String =>
    "scope/a with-element local is not visible after its with"

  fun apply(h: TestHelper) =>
    """
    A `with` element's initialiser sequence is transparent, so a
    local declared there is visible in the `with` body — and no
    further: it still dies with the `with`.
    """
    let source: String val =
      "class Foo\n" +
      "  fun f(): U32 =>\n" +
      "    with w = (let held: U32 = 1; held + 0) do\n" +
      "      held\n" +
      "    end\n" +
      "    held\n"
    let binder = _Bound(source)
    _Expect.binding(h, binder, source, "held", 2, BindLocal, 2,
      "the with body")
    _Expect.unbound(h, binder, source, "held", 3,
      "a with-element local escaped its with")

class \nodoc\ iso _TestADefaultArgLocalIsNotVisibleInTheBody
  is UnitTest
  fun name(): String =>
    "scope/a default-arg local is not visible in the body"

  fun apply(h: TestHelper) =>
    """
    ponyc scopes a parameter's default value, so a local declared
    there is visible inside the default and nowhere else.
    """
    let source: String val =
      "class Foo\n" +
      "  fun g(a: U32 = (let held: U32 = 1; held + 0)): U32 =>\n" +
      "    held\n"
    let binder = _Bound(source)
    _Expect.binding(h, binder, source, "held", 1, BindLocal, 1,
      "the default value's own sequence")
    _Expect.unbound(h, binder, source, "held", 2,
      "a default-arg local escaped into the body")
