use "json"
use ".."
use analysis = "pony_analysis"

primitive FactsRange
  """
  An analysis span as an LSP range.

  Both are zero-based lines and characters, and the characters are already
  counted in the encoding the span was built with, so this changes the type
  and not the meaning. It is the only place the two vocabularies meet.
  """
  fun apply(span: analysis.Span): LspPositionRange =>
    LspPositionRange(
      LspPosition(span.start_line, span.start_character),
      LspPosition(span.finish_line, span.finish_character))

primitive FactsSymbols
  """
  Document symbols from what syntax says about a buffer.
  """
  fun apply(facts: analysis.DocumentFacts): Array[DocumentSymbol] ref =>
    let built = Array[DocumentSymbol]
    let roots = Array[DocumentSymbol]
    for declaration in facts.declarations.values() do
      let symbol =
        DocumentSymbol(
          declaration.name,
          _kind(declaration.kind),
          FactsRange(declaration.span),
          FactsRange(declaration.name_span))
      built.push(symbol)
      match \exhaustive\ declaration.container
      | let container: USize =>
        try
          built(container)?.children.push(symbol)
        end
      | None =>
        roots.push(symbol)
      end
    end
    roots

  fun _kind(kind: analysis.DeclarationKind): I64 =>
    match kind
    | analysis.DeclInterface | analysis.DeclTrait =>
      SymbolKinds.sk_interface()
    | analysis.DeclStruct => SymbolKinds.sk_struct()
    | analysis.DeclField => SymbolKinds.field()
    | analysis.DeclConstructor => SymbolKinds.constructor()
    | analysis.DeclFunction | analysis.DeclBehaviour =>
      SymbolKinds.method()
    else
      // type, primitive, class, actor
      SymbolKinds.sk_class()
    end

primitive FactsFolding
  """
  Folding ranges from what syntax says about a buffer.
  """
  fun apply(facts: analysis.DocumentFacts): Array[JSONValue] =>
    let out = Array[JSONValue]
    for region in facts.foldable.values() do
      out.push(
        JSONObject
          .update("startLine", region.start_line.i64())
          .update("endLine", region.finish_line.i64()))
    end
    out

primitive FactsSelection
  """
  A selection range chain from the spans containing a position.

  The spans arrive innermost first, and the response is the innermost with
  each wider one hanging off it as a parent, so the chain is built from the
  outside in.
  """
  fun apply(spans: Array[analysis.Span] val): JSONValue =>
    var current: JSONValue = None
    var i = spans.size()
    while i > 0 do
      i = i - 1
      try
        var entry = JSONObject.update("range", FactsRange(spans(i)?).to_json())
        match current
        | let parent: JSONObject val =>
          entry = entry.update("parent", parent)
        end
        current = entry
      end
    end
    current
