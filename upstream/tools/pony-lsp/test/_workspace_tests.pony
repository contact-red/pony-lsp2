use "pony_test"
use "json"
use "files"
use ".."
use "../workspace"

primitive \nodoc\ _WorkspaceTests is TestList
  new make() =>
    None

  fun tag tests(test: PonyTest) =>
    test(_RouterFindTest)
    test(_PackageStateRemoveDocumentTest)
    test(_PackageStateRemoveDocumentMissingTest)
    test(_PackageStateDocumentPathsTest)
    test(_PackageStateDocumentStatesTest)
    test(_DocumentStateHoldsTheBuffer)
    test(_DocumentStateRefusesOlderText)
    test(_DocumentStateVersionsAreItsOwn)

class \nodoc\ iso _RouterFindTest is UnitTest
  fun name(): String => "router/find"

  fun apply(h: TestHelper) ? =>
    let file_auth = FileAuth(h.env.root)
    let this_dir_path = Path.dir(__loc.file())
    let folder = FilePath(file_auth, this_dir_path)
    let channel = FakeChannel
    let scanner = WorkspaceScanner.create(channel)
    let workspaces = scanner.scan(file_auth, this_dir_path)
    h.assert_eq[USize](4, workspaces.size())

    // Verify all expected workspaces were found
    // (order is not guaranteed because path.walk
    // uses filesystem enumeration order)
    let actual = Array[String]
    for ws in workspaces.values() do
      actual.push(ws.folder.path)
    end
    let expected =
      [ as String:
        folder.path
        folder.join("error_workspace")?.path
        folder.join("workspace")?.path
        folder.join("workspace with space")?.path
      ]
    h.assert_array_eq_unordered[String](expected, actual)

    // Verify router lookup works
    let router = WorkspaceRouter.create()
    // dummy, not actually in use
    let compiler = PonyCompiler("")
    let request_sender = FakeRequestSender
    let client = Client.from(JSONObject)

    let mgr =
      WorkspaceManager(
        workspaces(0)?,
        file_auth,
        channel,
        request_sender,
        client,
        compiler)
    router.add_workspace(folder, mgr)?

    let file_path = folder.join("main.pony")?
    let found = router.find_workspace(file_path.path)
    h.assert_isnt[(WorkspaceManager | None)](None, found)

class \nodoc\ iso _PackageStateRemoveDocumentTest is UnitTest
  fun name(): String => "package_state/remove_document"

  fun apply(h: TestHelper) ? =>
    let file_auth = FileAuth(h.env.root)
    let path = FilePath(file_auth, "/fake/path")
    let pkg = PackageState.create(path, FakeChannel)
    let doc_path = "/fake/path/main.pony"
    pkg.ensure_document(doc_path)
    h.assert_true(pkg.has_document(doc_path))
    pkg.remove_document(doc_path)?
    h.assert_false(pkg.has_document(doc_path))

class \nodoc\ iso _PackageStateRemoveDocumentMissingTest is UnitTest
  fun name(): String => "package_state/remove_document/missing"

  fun apply(h: TestHelper) =>
    let file_auth = FileAuth(h.env.root)
    let path = FilePath(file_auth, "/fake/path")
    let pkg = PackageState.create(path, FakeChannel)
    var errored = false
    try
      pkg.remove_document("/fake/path/missing.pony")?
    else
      errored = true
    end
    h.assert_true(errored)

class \nodoc\ iso _PackageStateDocumentPathsTest is UnitTest
  fun name(): String => "package_state/document_paths"

  fun apply(h: TestHelper) =>
    let file_auth = FileAuth(h.env.root)
    let path = FilePath(file_auth, "/fake/path")
    let pkg = PackageState.create(path, FakeChannel)
    pkg.ensure_document("/fake/path/a.pony")
    pkg.ensure_document("/fake/path/b.pony")
    let paths = Array[String]
    for p in pkg.document_paths() do
      paths.push(p)
    end
    h.assert_eq[USize](2, paths.size())
    h.assert_array_eq_unordered[String](
      ["/fake/path/a.pony"; "/fake/path/b.pony"],
      paths)

class \nodoc\ iso _PackageStateDocumentStatesTest is UnitTest
  fun name(): String => "package_state/document_states"

  fun apply(h: TestHelper) =>
    let file_auth = FileAuth(h.env.root)
    let path = FilePath(file_auth, "/fake/path")
    let pkg = PackageState.create(path, FakeChannel)
    pkg.ensure_document("/fake/path/a.pony")
    pkg.ensure_document("/fake/path/b.pony")
    let state_paths = Array[String]
    for s in pkg.document_states() do
      state_paths.push(s.path)
    end
    h.assert_eq[USize](2, state_paths.size())
    h.assert_array_eq_unordered[String](
      ["/fake/path/a.pony"; "/fake/path/b.pony"],
      state_paths)

class tag FakeRequestSender is RequestSender
  """
  Fake request sender for testing.
  """
  new tag create() => None

  fun tag send_request(
    method: String val,
    params: (JSONObject | JSONArray | None),
    notify: (ResponseNotify | None) = None)
  =>
    None

actor FakeChannel is Channel
  """
  Fake communication channel for testing.
  """
  be send(msg: Message val) =>
    None

  be log(data: String val, message_type: MessageType = Debug) =>
    None

  be set_notifier(notifier: Notifier tag) =>
    None

  be dispose() =>
    None

class \nodoc\ iso _DocumentStateHoldsTheBuffer is UnitTest
  fun name(): String => "document_state/holds the buffer"

  fun apply(h: TestHelper) ? =>
    """
    Until a client says otherwise there is no buffer, and what is on disk
    is all there is to go on.
    """
    let doc = DocumentState("/tmp/x.pony", FakeChannel)
    h.assert_is[(String val | None)](None, doc.text())
    h.assert_eq[USize](0, doc.text_version())

    h.assert_true(doc.set_text("class Foo", 1))
    h.assert_eq[String]("class Foo", doc.text() as String val)
    h.assert_eq[USize](1, doc.text_version())

class \nodoc\ iso _DocumentStateRefusesOlderText is UnitTest
  fun name(): String => "document_state/refuses older text"

  fun apply(h: TestHelper) ? =>
    """
    Notifications can arrive out of order, and replacing newer text with
    older would leave the server describing something the user has already
    moved past.
    """
    let doc = DocumentState("/tmp/x.pony", FakeChannel)
    h.assert_true(doc.set_text("second", 2))
    h.assert_false(doc.set_text("first", 1), "an older version was taken")
    h.assert_eq[String]("second", doc.text() as String val)

    // The same version again is taken: a client that sends no version at
    // all sends the same one every time, and refusing those would freeze
    // the buffer at the first edit.
    h.assert_true(doc.set_text("also second", 2))
    h.assert_eq[String]("also second", doc.text() as String val)

class \nodoc\ iso _DocumentStateVersionsAreItsOwn is UnitTest
  fun name(): String => "document_state/versions are its own"

  fun apply(h: TestHelper) ? =>
    """
    The text version is assigned here, advances on every text taken, and
    never repeats. It is not the client's version, which restarts at 1 when
    a document is reopened -- a reopen makes a fresh DocumentState, because
    didClose removes the old one, so the two never have to be reconciled.

    Refused text does not advance it either: a version that moved without
    the text moving would say a buffer had changed when it had not.
    """
    let doc = DocumentState("/tmp/x.pony", FakeChannel)
    doc.set_text("a", 1)
    let first = doc.text_version()
    doc.set_text("b", 2)
    let second = doc.text_version()
    h.assert_true(second > first, "the version did not advance")

    doc.set_text("stale", 1)
    h.assert_eq[USize](second, doc.text_version(),
      "refused text advanced the version")
    h.assert_eq[String]("b", doc.text() as String val)
