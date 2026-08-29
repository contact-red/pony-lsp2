use "pony_test"
use "../upstream/tools/lib/ponylang/pony_analysis"
use "../upstream/tools/lib/ponylang/pony_bind"

primitive \nodoc\ _BindTests is TestList
  fun tag tests(test: PonyTest) =>
    test(_TestResolvesInItsOwnPackage)
    test(_TestResolvesThroughAUse)
    test(_TestResolvesThroughAnAlias)
    test(_TestResolvesThroughBuiltin)
    test(_TestAnUnknownNameResolvesToNothing)
    test(_TestOwnPackageWinsOverBuiltin)
    test(_TestABodyEditDoesNotRebuildTheIndex)
    test(_TestARenameRebuildsTheIndex)
    test(_TestAddingAFileRebuildsTheIndex)
    test(_TestWorkspaceSymbols)
    test(_TestMembersCarryTheirOwner)
    test(_TestAnObjectLiteralDeclaresNothing)
    test(_TestOnlyPackageUsesAreImports)
    test(_TestARelativeUseNamesASibling)

primitive \nodoc\ _Workspace
  """
  A two-package workspace, built from string literals and never from a disk.
  """
  fun apply(): Binder =>
    let binder = Binder
    binder.set_source(
      "/w/app/main.pony",
      "use \"collections\"\n" +
      "actor Main\n" +
      "  new create(env: Env) =>\n" +
      "    None\n")
    binder.set_source(
      "/w/app/helper.pony",
      "class Helper\n" +
      "  fun run(): U32 =>\n" +
      "    1\n")
    binder.set_files("/w/app", ["/w/app/main.pony"; "/w/app/helper.pony"])

    binder.set_source("/w/lib/list.pony", "class List\n  fun size(): U32 => 0\n")
    binder.set_files("/w/lib", ["/w/lib/list.pony"])
    binder.set_package_path("collections", "/w/lib")
    binder

class \nodoc\ iso _TestResolvesInItsOwnPackage is UnitTest
  fun name(): String => "bind/resolves a name in its own package"

  fun apply(h: TestHelper) =>
    let binder = _Workspace()
    match binder.resolve("/w/app/main.pony", "Helper")
    | let found: BoundItem =>
      h.assert_eq[String]("/w/app/helper.pony", found.file)
      h.assert_eq[String]("Helper", found.name())
    else
      h.fail("Helper did not resolve")
    end

class \nodoc\ iso _TestResolvesThroughAUse is UnitTest
  fun name(): String => "bind/resolves a name through an unaliased use"

  fun apply(h: TestHelper) =>
    let binder = _Workspace()
    match binder.resolve("/w/app/main.pony", "List")
    | let found: BoundItem =>
      h.assert_eq[String]("/w/lib/list.pony", found.file)
    else
      h.fail("List did not resolve through the use")
    end

    // helper.pony has no `use`, so the same name must not resolve there.
    match binder.resolve("/w/app/helper.pony", "List")
    | let found: BoundItem =>
      h.fail("List resolved in a file that does not use it: " + found.file)
    end

class \nodoc\ iso _TestResolvesThroughAnAlias is UnitTest
  fun name(): String => "bind/resolves a qualified name through an alias"

  fun apply(h: TestHelper) =>
    let binder = Binder
    binder.set_source(
      "/w/app/main.pony", "use col = \"collections\"\nactor Main\n")
    binder.set_files("/w/app", ["/w/app/main.pony"])
    binder.set_source("/w/lib/list.pony", "class List\n")
    binder.set_files("/w/lib", ["/w/lib/list.pony"])
    binder.set_package_path("collections", "/w/lib")

    match binder.resolve("/w/app/main.pony", "col.List")
    | let found: BoundItem =>
      h.assert_eq[String]("/w/lib/list.pony", found.file)
    else
      h.fail("col.List did not resolve")
    end

    // An alias does not put the name into scope unqualified.
    match binder.resolve("/w/app/main.pony", "List")
    | let found: BoundItem =>
      h.fail("an aliased use leaked a bare name: " + found.file)
    end

class \nodoc\ iso _TestResolvesThroughBuiltin is UnitTest
  fun name(): String => "bind/resolves a builtin name with no use"

  fun apply(h: TestHelper) =>
    """
    No Pony file writes `use "builtin"`, so without the implicit package
    nothing resolves `U32`.
    """
    let binder = Binder
    binder.set_source("/w/app/main.pony", "actor Main\n")
    binder.set_files("/w/app", ["/w/app/main.pony"])
    binder.set_source("/w/builtin/u32.pony", "primitive U32\n")
    binder.set_files("/w/builtin", ["/w/builtin/u32.pony"])

    match binder.resolve("/w/app/main.pony", "U32")
    | let found: BoundItem =>
      h.fail("U32 resolved before builtin was declared: " + found.file)
    end

    binder.set_builtin("/w/builtin")
    match binder.resolve("/w/app/main.pony", "U32")
    | let found: BoundItem =>
      h.assert_eq[String]("/w/builtin/u32.pony", found.file)
    else
      h.fail("U32 did not resolve through builtin")
    end

class \nodoc\ iso _TestOwnPackageWinsOverBuiltin is UnitTest
  fun name(): String => "bind/the file's own package shadows builtin"

  fun apply(h: TestHelper) =>
    let binder = Binder
    binder.set_source("/w/app/main.pony", "primitive U32\n")
    binder.set_files("/w/app", ["/w/app/main.pony"])
    binder.set_source("/w/builtin/u32.pony", "primitive U32\n")
    binder.set_files("/w/builtin", ["/w/builtin/u32.pony"])
    binder.set_builtin("/w/builtin")

    match binder.resolve("/w/app/main.pony", "U32")
    | let found: BoundItem =>
      h.assert_eq[String]("/w/app/main.pony", found.file,
        "builtin shadowed a name the package declares itself")
    else
      h.fail("U32 did not resolve")
    end

class \nodoc\ iso _TestAnUnknownNameResolvesToNothing is UnitTest
  fun name(): String => "bind/an unknown name resolves to nothing"

  fun apply(h: TestHelper) =>
    let binder = _Workspace()
    match binder.resolve("/w/app/main.pony", "Absent")
    | let found: BoundItem => h.fail("resolved to " + found.file)
    end

class \nodoc\ iso _TestABodyEditDoesNotRebuildTheIndex is UnitTest
  fun name(): String => "bind/a body edit does not rebuild the index"

  fun apply(h: TestHelper) =>
    """
    The reason `BoundItem` carries no span.

    `FINDINGS.md` names file-level invalidation as the limiting flaw: an
    edit to one body invalidated everything its file declared. Here the
    declaration list compares equal, the engine backdates it, and the index
    is never rebuilt -- which is observable as the same object coming back.
    """
    let binder = _Workspace()
    let before = binder.index("/w/app")

    binder.set_source(
      "/w/app/helper.pony",
      "class Helper\n" +
      "  fun run(): U32 =>\n" +
      "    2 + 40\n")

    let after = binder.index("/w/app")
    h.assert_is[PackageIndex](before, after,
      "the index rebuilt after an edit that declared nothing new")

class \nodoc\ iso _TestARenameRebuildsTheIndex is UnitTest
  fun name(): String => "bind/a rename rebuilds the index"

  fun apply(h: TestHelper) =>
    """
    The other half. Backdating that never lets anything through would pass
    the test above and be useless.
    """
    let binder = _Workspace()
    let before = binder.index("/w/app")

    binder.set_source(
      "/w/app/helper.pony",
      "class Assistant\n" +
      "  fun run(): U32 =>\n" +
      "    1\n")

    let after = binder.index("/w/app")
    h.assert_isnt[PackageIndex](before, after, "the index did not rebuild")
    match binder.resolve("/w/app/main.pony", "Assistant")
    | let found: BoundItem =>
      h.assert_eq[String]("/w/app/helper.pony", found.file)
    else
      h.fail("the new name did not resolve")
    end
    match binder.resolve("/w/app/main.pony", "Helper")
    | let found: BoundItem => h.fail("the old name still resolves")
    end

class \nodoc\ iso _TestAddingAFileRebuildsTheIndex is UnitTest
  fun name(): String => "bind/adding a file rebuilds the index"

  fun apply(h: TestHelper) =>
    let binder = _Workspace()
    binder.index("/w/app")

    binder.set_source("/w/app/extra.pony", "primitive Extra\n")
    binder.set_files(
      "/w/app",
      ["/w/app/main.pony"; "/w/app/helper.pony"; "/w/app/extra.pony"])

    match binder.resolve("/w/app/main.pony", "Extra")
    | let found: BoundItem =>
      h.assert_eq[String]("/w/app/extra.pony", found.file)
    else
      h.fail("a declaration in a newly added file did not resolve")
    end

class \nodoc\ iso _TestWorkspaceSymbols is UnitTest
  fun name(): String => "bind/workspace symbols span packages"

  fun apply(h: TestHelper) =>
    let binder = _Workspace()

    var entities: USize = 0
    for item in binder.matching("").values() do
      if item.is_entity() then entities = entities + 1 end
    end
    h.assert_eq[USize](3, entities, "Main, Helper and List")

    let matched = binder.matching("hel")
    h.assert_eq[USize](1, matched.size(), "case-insensitive substring")
    try
      h.assert_eq[String]("Helper", matched(0)?.name())
    else
      h.fail("no match")
    end

class \nodoc\ iso _TestMembersCarryTheirOwner is UnitTest
  fun name(): String => "bind/a member is named under its entity"

  fun apply(h: TestHelper) =>
    let binder = _Workspace()
    var found = false
    for item in binder.declarations("/w/app/helper.pony").values() do
      match item.path
      | let member: MemberPath =>
        if member.member == "run" then
          found = true
          h.assert_eq[String]("Helper", member.owner.entity)
          h.assert_eq[String]("/w/app", member.owner.package)
        end
      end
    end
    h.assert_true(found, "the method was not projected as a member")

class \nodoc\ iso _TestAnObjectLiteralDeclaresNothing is UnitTest
  fun name(): String => "bind/an object literal declares nothing"

  fun apply(h: TestHelper) =>
    """
    An `object` literal has no name, so its methods are enclosed by a method
    rather than by an entity and no name path reaches them. Attributing them
    to the enclosing entity would put an `apply` in the index that `Outer`
    does not have.
    """
    let binder = Binder
    binder.set_source(
      "/w/app/outer.pony",
      "class Outer\n" +
      "  fun make(): Any =>\n" +
      "    object\n" +
      "      fun apply(): U32 => 1\n" +
      "    end\n")
    binder.set_files("/w/app", ["/w/app/outer.pony"])

    let names = Array[String val]
    for item in binder.declarations("/w/app/outer.pony").values() do
      names.push(item.name())
    end
    h.assert_eq[USize](2, names.size(), "expected Outer and make only")
    h.assert_true(names.contains("Outer", {(a, b) => a == b }))
    h.assert_true(names.contains("make", {(a, b) => a == b }))
    h.assert_false(names.contains("apply", {(a, b) => a == b }),
      "an object literal's method reached the index")

class \nodoc\ iso _TestOnlyPackageUsesAreImports is UnitTest
  fun name(): String => "bind/only a package use is an import"

  fun apply(h: TestHelper) =>
    """
    ponyc has three `use` schemes and only `package:` names a Pony package.
    `lib:` links a native library and `path:` adds a search path; reading
    either as a package name invents a dependency on one that cannot exist.
    """
    let binder = Binder
    binder.set_source(
      "/w/app/main.pony",
      "use \"lib:rt\"\n" +
      "use \"path:/opt/pony\"\n" +
      "use @exit[None](code: I32)\n" +
      "use \"package:collections\"\n" +
      "use \"strings\"\n" +
      "actor Main\n")
    binder.set_files("/w/app", ["/w/app/main.pony"])

    let found = binder.imports("/w/app/main.pony")
    h.assert_eq[USize](2, found.size(), "expected collections and strings")
    try
      h.assert_eq[String]("collections", found(0)?.package)
      h.assert_eq[String]("strings", found(1)?.package)
    else
      h.fail("imports missing")
    end

class \nodoc\ iso _TestARelativeUseNamesASibling is UnitTest
  fun name(): String => "bind/a relative use names a sibling package"

  fun apply(h: TestHelper) =>
    """
    `use ".."` names the package one directory up. ponyc's own standard
    library does this from its benchmark subpackages, and without it those
    files import nothing.
    """
    let binder = Binder
    binder.set_source(
      "/w/lib/benchmarks/main.pony", "use \"..\"\nactor Main\n")
    binder.set_files("/w/lib/benchmarks", ["/w/lib/benchmarks/main.pony"])
    binder.set_source("/w/lib/list.pony", "class List\n")
    binder.set_files("/w/lib", ["/w/lib/list.pony"])

    match binder.resolve("/w/lib/benchmarks/main.pony", "List")
    | let found: BoundItem =>
      h.assert_eq[String]("/w/lib/list.pony", found.file)
    else
      h.fail("a relative use did not reach the parent package")
    end
