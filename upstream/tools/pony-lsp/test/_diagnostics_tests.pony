use ".."
use "pony_test"
use "files"
use "json"

primitive \nodoc\ _DiagnosticTests is TestList
  new make() =>
    None

  fun tag tests(test: PonyTest) =>
    test(_DiagnosticTest)
    test(_SyntaxDiagnosticTest)

class \nodoc\ iso _DiagnosticTest is UnitTest
  fun name(): String =>
    "diagnostics/compiler_error_to_diagnostics"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)

    let workspace_dir = Path.join(Path.dir(__loc.file()), "error_workspace")
    let harness =
      TestHarness.create(
        h,
        PonyCompiler("", try h.env.args(0)? else "" end),
        object iso is MessageHandler
          var received_diagnostics: USize = 0
          let expected_messages:
            Array[String] val =
            [
              "argument not assignable to parameter"
              "argument type is String val"
              "parameter type requires U8 val^"
              "String val is not a subtype of U8 val^"
              "cannot infer type of fromb"
            ]

          fun handle_request(
            h: TestHelper,
            req: RequestMessage val,
            server: BaseProtocol)
          =>
            h.log("Received request: " + req.json().print())
            match req.method
            | Methods.workspace().configuration() =>
              // this will initialize the compiler
              server(
                ResponseMessage.create(req.id, JSONArray).string().iso_array())
              // send did_open notification to trigger compilation
              server(
                Notification(
                  Methods.text_document().did_open(),
                  JSONObject
                    .update(
                      "textDocument",
                      JSONObject
                        .update(
                          "uri",
                          Uris.from_path(Path.join(workspace_dir, "main.pony")))
                        .update("languageId", "pony")
                        .update("version", I64(1))
                        // The document's real contents. A placeholder
                        // was harmless while nothing read the buffer;
                        // now the server parses it and reports, quite
                        // correctly, that it is not Pony.
                        .update(
                          "text",
                          _FileText(h, Path.join(workspace_dir, "main.pony"))))
                ).string().iso_array()
              )
            end

          fun ref handle_notification(
            h: TestHelper,
            notification: Notification,
            server: BaseProtocol)
          =>
            h.log("received notification: " + notification.json().print())
            match notification.method
            | Methods.text_document().publish_diagnostics() =>
              try
                for diagnostic in
                  JSONNav(notification.params)("diagnostics")
                    .as_array()?.values()
                do
                  received_diagnostics = received_diagnostics + 1
                  h.log(
                    "received diagnostic " + received_diagnostics.string() +
                    ": " + notification.json().print())
                  // strip off linebreak from error message
                  let message: String val =
                    recover val
                      JSONNav(diagnostic)("message").as_string()?.clone()
                        .> strip()
                    end
                  h.assert_true(
                    expected_messages.contains(
                      message,
                      {(l, r) => l == r }),
                    "Unexpected diagnostic message: '" + message + "'")
                  if
                    received_diagnostics == 5
                  then
                    h.complete(true)
                  end
                end
              else
                h.fail(
                  "Weird diagnostics notification: " + notification.string())
              end
            end

          fun ref handle_response(
            h: TestHelper,
            res: ResponseMessage,
            server: BaseProtocol)
          =>
            h.log("received response: " + res.json().print())
            try
              h.assert_true(RequestIds.eq(I64(0), res.id as RequestId))
            else
              h.fail("No RequestId")
            end
            // send initialized notification
            server(
              Notification(Methods.initialized(), None).string().iso_array())
        end,
        {(h: TestHelper, harness: TestHarness ref): Bool => true }
        where
          after_sends = 3,
          after_logs = USize.max_value()
      )
    harness.send_to_server(LspMsg.initialize(workspace_dir))

class \nodoc\ iso _SyntaxDiagnosticTest is UnitTest
  """
  A buffer that does not parse produces diagnostics from its syntax alone.

  No compiler runs here -- TestCompiler does nothing -- so anything that
  arrives came from the buffer. That is the point: before this, a file was
  described only after a whole-program compile of the workspace it is in,
  so a file that would not compile was a file with nothing to say about it.
  """
  fun name(): String => "diagnostics/syntax_diagnostics_from_the_buffer"

  fun apply(h: TestHelper) =>
    h.long_test(10_000_000_000)
    let workspace_dir = Path.join(Path.dir(__loc.file()), "workspace")

    let harness =
      TestHarness.create(
        h,
        TestCompiler(h),
        object iso is MessageHandler end,
        {(h: TestHelper, harness: TestHarness ref): Bool =>
          var found = false
          for msg in harness.sent.values() do
            match msg
            | let n: Notification val =>
              if n.method == Methods.text_document().publish_diagnostics()
              then
                try
                  // Diagnostics about a buffer say which version of it
                  // they describe. A compile's do not.
                  JSONNav(n.params)("version").as_i64()?
                  let reported =
                    JSONNav(n.params)("diagnostics").as_array()?
                  if reported.size() > 0 then
                    found = true
                  end
                end
              end
            end
          end
          if found then
            h.complete(true)
          end
          found}
        where
          after_sends = 2,
          after_logs = USize.max_value()
      )

    harness.send_to_server(LspMsg.initialize(workspace_dir))
    // Messages from one sender to one receiver keep their order, so this
    // is handled after the initialize above.
    harness.send_to_server(
      Notification(
        Methods.text_document().did_open(),
        JSONObject
          .update(
            "textDocument",
            JSONObject
              .update(
                "uri", Uris.from_path(Path.join(workspace_dir, "main.pony")))
              .update("languageId", "pony")
              .update("version", I64(1))
              .update("text", "class 123 !!!\n"))
      ).string().iso_array())

primitive \nodoc\ _FileText
  """
  A file's contents, for a test that has to open a document the way a
  client does.
  """
  fun apply(h: TestHelper, path: String): String val =>
    try
      let file =
        OpenFile(FilePath(FileAuth(h.env.root), path)) as File
      recover val String.from_array(file.read(file.size())) end
    else
      h.fail("could not read " + path)
      ""
    end
