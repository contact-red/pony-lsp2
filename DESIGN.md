# A query-based Pony front end for pony-lsp: design

Answers the five questions in `QUERY_BRIEF.md`. Produced by the design
ensemble in `pony-software-design` — three design personas, five evaluation
personas, two synthesis passes — with every load-bearing claim about libponyc
and pony-lsp verified against the source rather than taken from a persona.

Nothing here is implemented. Where a claim rests on something not yet measured,
it says so.

## Summary

The boundary should carry **facts, not trees**: immutable per-document values
describing declarations and references, keyed by a stable name path, and
stamped with the version of the text they describe and the depth of analysis
behind them. Cross-document questions are asked of an actor rather than read
from a pushed value.

The existing `LspCompiler` / `CompilerNotify` / `Program val` seam is replaced
rather than preserved. It cannot express "a tree and some errors", which is the
normal state of a file being edited, and that single defect is why one syntax
error currently costs every feature at once.

**The first slice is a Pony lexer and parser, lossless and error-tolerant,
producing a syntax tree whose elements carry widths rather than offsets.**
libponyc's parser cannot serve a language server: it frees the whole tree on
any syntax error, so it has nothing to say about a buffer being typed, and its
AST carries no trivia, which is why two tools already scan raw source bytes
alongside it. Neither is a defect — both are correct for a batch compiler —
and neither is fixable from outside.

The grammar itself is not new work. ponyc defines 129 rules and ponyq ports
exactly 129, against a runtime of about twenty functions. **The rules are the
twice-validated part; the runtime is the small piece that decides what happens
on error.** The first slice ports the lexer, builds the tree, rewrites the
runtime so that no rule can fail, and ports the 64 rules covering items,
signatures and types — with method bodies as a block skeleton that the
remaining 65 rules replace later. (Both halves are now built; the skeleton is
gone.)

What the user gets: document symbols, folding range, selection range and syntax
diagnostics answering on every keystroke against the unsaved buffer, including
while the file does not compile and while it does not parse. The other twelve
features keep answering through libponyc, stamped with the version they
describe.

## Decisions taken before this document

Recorded because they constrain everything below.

| Decision | Choice |
|---|---|
| Coding conventions | Preserved — ~79 columns, `this.`-prefixed calls, `\exhaustive\`, docstrings on public API, `pony_test` |
| Interface design | **Free to change.** The existing seam is not a constraint |
| libponyc's limits | **Not a constraint.** The parser is written in Pony rather than shaped around what libponyc can do |
| Rewriting pony-lsp | Acceptable if warranted. It is not warranted; see "What this costs in rewritten LSP code" |
| Stale reads while a buffer is dirty | Per-feature policy — serve the newest value that exists, always stamped, each feature decides. Writes refuse |
| First slice target | Unsaved-buffer freshness for the four syntax-tier features, which an error-tolerant parser makes reachable. See question 4 |
| Buffer retention | No eviction in the first slice; cap the document count |
| Boundary scope | The tree is designed for pony-lint too and carries no LSP vocabulary; migrating pony-lint is deferred and nothing blocks on it |
| Non-stdlib dependencies | None. Everything here uses `collections`, `collections/persistent`, `json`, `files`, `itertools` |

## What was measured

All timings on this machine, 64 cores, ponyc 0.69.1, `ponyc --pass=<P>`,
cumulative:

| pass | `collections` | `stdlib` |
|---|---|---|
| parse | 0.07s | 0.04s |
| syntax | 0.07s | 0.05s |
| scope | 0.19s | — |
| import | 0.17s | — |
| name | 0.18s | — |
| flatten | 0.20s | — |
| traits | 0.25s | — |
| refer | 0.26s | — |
| **expr** | **1.53s** | **6.15s** |
| final | 1.75s | 6.71s |

pony-lsp compiles to `PassFinaliser` on every open and every save, whole
program, serialised through one `PonyCompiler` actor because libponyc is not
thread-safe. **Type checking is 83% of a compile.** Everything through `refer`
costs 0.26s of 1.53s.

`packages/net` at `--pass=expr` is 2.25s, for a sense of the spread.

## Question 1 — the output boundary

### The options

**A. Materialise something `Program`-shaped.** The new package produces a value
the existing 23 AST-walking files can consume unchanged. Incrementality stops
at the boundary.

*Rejected.* The AST those files walk is not a syntax tree — it is libponyc's
tree *after* the `expr` pass, carrying `ast_data` back-pointers written by
`refer`, desugared `tk_newref` nodes inside same-position `tk_call`s, trait
default bodies grafted onto implementers with foreign `source_file`s, and
reified type aliases producing mixed-source subtrees. `PositionIndex._build_index`
carries a paragraph of docstring explaining that it must ignore `AST.visit`'s
source filter to reach user nodes underneath foreign-source parents.
`_ResolveASTTarget` skips synthetic `tk_newref`s by comparing positions with
their parent `tk_call`. `symbols.pony` spends roughly a hundred lines filtering
synthesized constructors and `add_comparable`'s `eq`/`ne`.

To keep those files working, the new front end would have to reproduce
libponyc's desugaring artifacts faithfully — including the ones pony-lsp works
around. That is bug-compatible emulation of an internal representation, with
"the workarounds still fire correctly" as its success criterion. It also does
not help: producing a whole `Program`-shaped value per request costs what
computing one costs, which is the thing being escaped.

**B. Rewrite the feature layer to ask questions, one query per request.**
`hover(position)`, `definition(position)`, and so on.

*Rejected in that form.* If the queries are named from the LSP's requests, the
feature layer has moved into the front end and the front end starts owning
markdown. If they are named from the compiler's internals, the boundary leaks
passes. And it cannot be filled one document at a time, so there is no slice
that both ships and beats a compile.

**C. Per-document immutable fact values, pushed; cross-document questions
pulled.** *Recommended.* Detailed below.

**D. Export a lossless syntax tree**, rust-analyzer's green/red model, with
facts as a consumer-side projection.

**Adopted, underneath C rather than instead of it.** Losslessness and error
recovery are the same mechanism — a parser that keeps what it could not
interpret is a parser that produces a tree for a broken buffer — and a
language server needs both. So the parser exports a lossless tree and the front
end projects facts from it. Three layers, not two: the tree is what `pony-lint`
would consume, the facts are what pony-lsp consumes, and no LSP vocabulary
appears below the top layer. See questions 3 and 4.

### The recommendation, and why

> The front end hands pony-lsp immutable per-document analysis values —
> declarations and references, keyed by a stable identity, stamped with the
> text version and the analysis depth behind them. Questions that span
> documents are asked of an actor and answered asynchronously.

Three properties earn it.

**The unit is a document, because every feature's question is.** Ten of the
sixteen features enter through `_find_node_and_module(path, line, column)`;
four more read `doc.module()`. Not one starts from a program. The four that
reach across the workspace — find references, rename, call hierarchy, type
hierarchy subtypes — do not want a tree either; they want "every place in the
workspace matching this identity", which they currently get by walking every
module and comparing.

**The fact vocabulary already exists and was not invented here.**
`workspace/hover.pony` lines 3-90 define `EntityInfo`, `MethodInfo`,
`FieldInfo`, `LocalVarInfo` and `ParamInfo`: five `class val` types with no AST
in them, consumed by pure `format_*` functions. Someone solving this exact
problem inside one file already drew the boundary. Two design personas found it
independently from opposite directions.

**Identity must be a name path, not a position.** `FINDINGS.md` names positional
identity as the flaw to fix — an edit to one body renumbers its siblings, which
is where its 33% re-check figure comes from. pony-lsp has the same bug already:
`language_server.pony:62-68` round-trips a call-hierarchy item through the
client as a URI plus `selectionRange.start` and re-finds the node by position,
so an edit between `prepareCallHierarchy` and `incomingCalls` resolves to a
different node, silently.

### What this costs in rewritten LSP code

Splitting the 9,219 lines by whether a file uses `pony_compiler`:

| | lines |
|---|---|
| Representation-independent | 2,998 |
| Coupled to the libponyc AST | 6,221 |

The independent 2,998 — `language_server.pony` (672), `message.pony`,
`notifier.pony`, `client.pony`, `methods.pony`, `channel.pony`,
`percent_encoding.pony`, `uris.pony`, `corral.pony`, `workspace_scanner.pony`,
`settings.pony` — is JSON-RPC framing, lifecycle, capability negotiation, URI
handling and corral discovery. None of it cares what a Pony type is. **It is
kept whatever the front end becomes.**

Two files sit in that column dishonestly: `inlay_hint_source.pony` (315 lines)
and `signature_help_source.pony` (69) scan raw source bytes because the AST
does not carry what those features need. They are independent of
`pony_compiler` only because they gave up on it, and they are deleted rather
than kept.

Of the coupled 6,221, a large fraction is not knowledge worth preserving.
`_ResolveASTTarget` (75), `ASTIdentifier` (94) and `DefinitionResolver` (200)
are three decoders that between them answer one question. The filtering in
`symbols.pony` and the desugaring quirks the folding-range tests document are
compensation for artifacts of a post-`expr` AST that this front end does not
produce. Discarding them discards the workaround along with the thing worked
around.

**A rewrite is not warranted, for one reason: the tests.** `tools/pony-lsp/test`
is 12,646 lines across 29 files, and only `main.pony` mentions `pony_compiler`
at all — it does not use it. The other 28 drive a real server against a
per-feature fixture workspace and assert on LSP JSON. They pass for a rewritten
server and a migrated one equally, so a rewrite buys nothing the migration does
not, while giving up the ability to tell, feature by feature, exactly when
behaviour changed.

That net has a hole, and it is sized in "What is uncertain": 116 assertions
across hover, highlight, definition, type-definition and workspace-symbol
suites pass against a server that answers null to everything.

### The types

Two axes travel with every answer, and they are independent.

```pony
type TextVersion is USize
  """
  Identifies one immutable text for one document. Assigned by the server,
  not taken from the client: the client's `textDocument.version` orders the
  notifications the server receives, restarts at 1 when a document is
  reopened, and is absent for a file on disk. This one identifies the text
  an answer's coordinates index into, and never repeats within a session.
  """
```

Server-assigned rather than client-supplied because the client's version
restarts on reopen — VS Code returns to 1 — which would let a stale identity
pass a version check against different text. A bare `USize` because it carries
no invariant to protect.

```pony
type AnalysisDepth is (Parsed | Bound | Typed)
  """
  How far analysis has taken a document. Ordered by `level()`. Compare
  levels rather than matching on the union, so that inserting a tier does
  not break every call site.
  """

primitive Parsed
  """
  The text is a tree. Decides shape, source spans, the outline and what is
  foldable. Decides nothing about names.
  """
  fun level(): U8 => 0

primitive Bound
  """
  Names introduced by declarations in this file are attached to those
  declarations, and type and package names resolve. Decides locals,
  parameters, type references and package references. Decides nothing that
  needs a receiver's type: method calls, field accesses and tuple element
  references are all undecided here.
  """
  fun level(): U8 => 1

primitive Typed
  """Every expression has a type. Decides everything."""
  fun level(): U8 => 2
```

`Bound` is named for what it delivers, not for what one might hope. An earlier
draft called it `Resolved` and claimed it served find-references, rename,
document highlight and call hierarchy. It does not, and the mistake is worth
recording because it is easy to make: `pass/refer.c` sets `TK_PACKAGEREF`
(:512), `TK_TYPEREF` (:525, :633, :750), `TK_PARAMREF` (:574), `TK_VARREF`
(:589) and `TK_LETREF` (:591), but `TK_NEWREF` (:53), `TK_NEWBEREF` (:57, :96),
`TK_BEREF` (:163), `TK_FUNREF` (:167), `TK_TUPLEELEMREF` (:347) and the
`TK_FVARREF`/`TK_FLETREF`/`TK_EMBEDREF` family (:398, :403, :408) are all set
in `expr/postfix.c`. `DefinitionResolver.resolve` reaches
`receiver.ast_type()` for the funref family, which `expr` writes.

This is not a libponyc artifact. `x.foo()` cannot be resolved without knowing
what `x` is, in any implementation. **Depth is therefore a property of the
referent, not of the feature**: go-to-definition on a local needs `Bound`, on a
method call needs `Typed`. Migration proceeds by referent kind, and one feature
can be partly migrated.

```pony
class val Provenance
  """
  What stands behind an answer: the workspace revision it was computed at,
  and how deep the analysis went.
  """
  let revision: USize
  let depth: AnalysisDepth

class val SourceSpan
  """
  A range in a named version of a named document. The version travels with
  the span rather than with the answer, because one answer can span several
  documents at different versions -- a reference list where only the edited
  file has moved.
  """
  let document: String val
  let version: TextVersion
  let start_line: USize
  let start_char: USize
  let end_line: USize
  let end_char: USize
```

The coordinates are flattened rather than held as an `LspPositionRange`, for
two reasons. `LspPositionRange` holds `let _start` and `let _end`, not `embed`,
so a nested span is four heap objects for four machine words, and there is one
span per reference. And `LspPositionRange` is an LSP presentation type, which
has no business inside a fact about Pony source — the same layering defect this
design fixes elsewhere.

```pony
type Answer[T: Any val] is (Known[T] | Absent | Unavailable)

class val Known[T: Any val]
  """The question has an answer, and this is it."""
  let value: T
  let from: Provenance

class val Absent
  """
  The question has been decided and there is nothing. `from` records at what
  depth it was decided, because "no symbol here" at `Parsed` and at `Typed`
  are different claims.
  """
  let from: Provenance

type Unavailable is
  ( NotParseable | NotYetKnown | Superseded
  | PackageNotIndexed | DocumentNotInWorkspace )
```

`Absent` is deliberately outside `Unavailable`: it means never ask again, where
every `Unavailable` variant means ask again under stated conditions. The five
are separate because the caller does something different for each:

| Variant | Carries | Caller does |
|---|---|---|
| `NotParseable` | `document`, `version` | Send null. Do **not** log as an error — a buffer mid-keystroke is normal. Retry is pointless until the text changes |
| `NotYetKnown` | `have: (AnalysisDepth \| Unanalysed)`, `needs: AnalysisDepth`, `running: (Idle \| Analysing)` | If `running`, waiting works. If `Idle`, trigger analysis. The only variant where retry is the right move |
| `Superseded` | `asked_about: TextVersion`, `current: TextVersion` | Re-ask at the current version. Never send the answer |
| `PackageNotIndexed` | `package: String val` | Surface to the user — a `PONYPATH` or corral problem they can fix |
| `DocumentNotInWorkspace` | `document: String val` | Surface to the user — a different problem with a different fix |

`have` is a union with `Unanalysed` because "what depth do you have" has no
answer when nothing has been analysed. Each variant carries
`fun describe(): String val`, matching `Diagnostic` and `Error`. **No
`describe()` may include source text** — the server holds unsaved buffers and
`Channel.log` forwards to the editor as `window/logMessage`.

```pony
class val EntityPath is (Hashable & Equatable[EntityPath])
  """
  Names a type declaration by the qualified package name and the entity
  name. Stable across edits that neither rename nor delete it, so it can be
  handed to a client and handed back.
  """
  let package: String val
  let entity: String val
  let _hash: USize

class val MemberPath is (Hashable & Equatable[MemberPath])
  """Names a method or field of an entity. Stable on the same terms."""
  let owner: EntityPath
  let member: String val
  let _hash: USize

class val LocalDef is (Hashable & Equatable[LocalDef])
  """
  Names a local or a parameter. A local has no name that survives an edit,
  so this identity is scoped to one version of one document and is refused
  against any other. `EntityPath` and `MemberPath` carry no version for the
  opposite reason: they survive.
  """
  let document: String val
  let version: TextVersion
  let method: MemberPath
  let ordinal: USize

type DefinitionRef is (EntityPath | MemberPath | LocalDef)
```

The hash is computed once in the constructor and stored. `String.hash()`
re-hashes the whole string on every call and `String.eq` is a `memcmp` with no
pointer fast path; a `declaration(id)` lookup or a find-references comparison
happens on the order of a hundred thousand times per workspace query. Today's
`References` compares by `AST.eq`, which is pointer equality — moving to a
name path is the right correctness call and is not free, and the stored hash is
what pays for it.

Two rules on `DefinitionRef` that the boundary owns rather than the engine:

- **Trait default bodies need a canonicalisation rule.** `call_hierarchy.pony`
  documents that it chose position identity *specifically* so that a default
  body grafted onto three implementers matches. Under name paths, `{T, foo}`,
  `{C1, foo}` and `{C2, foo}` compare unequal while sharing a span, so
  find-references on a trait default would return a strict subset of today's
  results — and no `Answer` variant catches it, because the vocabulary
  distinguishes "could not determine" from "determined nothing", not
  "determined a subset". `Declaration` therefore carries both `id` and
  `declared_by`, and a reference to an inherited member resolves to the
  declaring entity.
- **`LocalDef.ordinal` arrives from the client and is bounds-checked.** Out of
  range is `Absent`, never an index.

```pony
type TypeAnnotation is
  (WrittenType | InferredType | NotAnnotated | NotYetTyped)

class val WrittenType
  """The type as the source writes it. Available at `Parsed`."""
  let text: String val

class val InferredType
  """
  A type the source did not write and analysis worked out. Available only
  at `Typed`.
  """
  let text: String val

primitive NotAnnotated
  """The source declares no type here and none is inferred for it."""

primitive NotYetTyped
  """The source declares no type and analysis has not reached one."""
```

This is per-field rather than read off the answer's depth, because
depth-dependence is per-field: a method's *written* return type is available at
`Parsed`, a local's *inferred* type is not available until `Typed`. It replaces
`LocalVarInfo.var_type: String`, which is `""` today for both "no annotation
written" and "not known", so the formatter cannot tell them apart. It is also
the whole of the inlay-hint feature: `InlayHintSource`'s 315 lines of byte
scanning exist to answer "was the capability written in the source?", which the
producer knows and now states.

One caveat to write into `WrittenType`'s docstring: at `Parsed` its text
carries no inferred capability. `_type_formatter.pony` reaches
`type_node.definitions()(0)?` and then reads the capability off the nominal's
cap child, which is `tk_none` before `refer`. A hover test asserting
`"let integer: U32 val"` against source reading `let integer: U32 = 42` is
asserting on something the source does not contain.

### The state model

Read off `workspace/state.pony`, a document today is in one of seven states,
encoded across `DocumentState`'s five `FromCompilerRun[T]` fields, two
`_compiler_run_id`s, `WorkspaceManager._compiling: Bool` and
`_awaiting_compilation_for`. States 1, 2, 4 and 7 all present as `None`; states
3, 5 and 6 all present as `Module val`. **The type system distinguishes none of
them**, and the collapse of 3, 5 and 6 into one type is the confident-wrong-
answer bug.

The replacement records **what is known at each depth**, not one depth:

```pony
class val DocumentAnalysis
  """
  What the front end knows about one document, and what it is doing about
  it.

  `deepest` and `shallowest_current` are both kept because analysis
  arrives in rungs and a deeper answer about older text is often better
  than a shallower answer about newer text. A consumer picks per feature;
  see the stale policy table.
  """
  let reached: Array[Reached] val
    """
    One entry per depth that has ever produced facts, holding the newest
    version and revision that reached it. Never shrinks except by
    eviction.
    """
  let current: TextVersion
    """The newest text the server holds for this document."""
  let running: (Idle | Analysing)

class val Reached
  let depth: AnalysisDepth
  let version: TextVersion
  let revision: USize

primitive Idle

class val Analysing
  let version: TextVersion
  let target: AnalysisDepth
```

**A rung must not replace what a deeper rung already established.** An earlier
draft held one `(version, depth)` pair and overwrote it, so the shallow rung of
a new compile would discard the typed facts of the previous one — and ten of
the eighteen feature rows are `Typed` or have a `Typed` half. Those features
answer today, from the last successful compile. Overwriting would make them
return null for the whole window between the shallow answer and the deep one —
milliseconds for a parse, over a second for a compile — on every edit. **A
shallow publication that replaces a deeper one is strictly worse than not
publishing at all**, and this is the shape that avoids it: a consumer can hold version 4 at `Typed` and
version 5 at `Bound` simultaneously and choose between them.

That also fixes what invariant I4 says. Depth is non-monotonic only through
*eviction*; it is not a licence for a rung to demote a document.

The derived states a consumer asks about:

- **`Unanalysed`** — `reached` is empty.
- **`Analysed` at depth d** — some entry has `depth = d` and `version =
  current`. Coordinates from it index the text the server holds.
- **`Stale` at depth d** — an entry has `depth = d` and an older version, and
  something is running or schedulable.
- **`Unparseable`** — the newest text failed to parse, so no entry names it and
  waiting will not help; only an edit will.

`Stale` and `Unparseable` are distinguished for the same reason `NotYetKnown`
and `NotParseable` are distinguished in the error vocabulary: in one, waiting
works; in the other it never will.

**Revisions travel with the state, not only with an answer.** `Provenance`
carries a revision and an earlier draft discarded it here, which let two
answers from different revisions compose: go-to-type-definition takes `type_of`
at revision *r* and `definition` at revision *r+1*, both spans current for
their own document, both passing every version check, and the jump lands on a
stale line. Neither answer produces that alone. **A composed answer must come
from a single revision**, and that is checkable only if the revision is here.

Transitions:

- text accepted at a new version → `current` advances; `reached` is untouched
- analysis completes at depth d, version v, revision r → the entry for d is
  replaced if v is newer than the one it holds, and only then
- analysis starts → `running` becomes `Analysing`; completes → `Idle`
- **the deepest entry is older than `current` and `running` is `Idle` ⇒
  schedule.** Without this rule a stale document is terminal

`fun should_schedule(): Bool` lives on `DocumentAnalysis`, because otherwise
that rule lives in whoever holds the value and no pure test reaches it.

This is data pushed to a consumer that decides, not behaviour dispatched by
state, so it is a union of values rather than the trait-based state machine
`pony-ref` recommends for stateful actors. The engine actor's own lifecycle is
a separate question and probably does want one.

`DocumentAnalysis` gets pure `val` transitions — `with_text`, `with_analysis`,
`analysing` — so a unit test can enumerate every combination without a server.
`_workspace_tests.pony` already proves the package is directly unit-testable
this way; none of the seven current states has a test today.

### The facts, and the questions

Both were used without definition in an earlier draft, which mattered: without
a public constructor for `DocumentFacts`, every stale policy and every depth row
is testable only through a running server.

```pony
class val DocumentFacts
  """
  Everything known about one document at one depth. Constructed by a
  projection from whatever produced it -- `FactsFromModule` over a compiled
  module today, a query engine later -- and directly constructible by a
  test.
  """
  let document: WorkspaceDocument
  let version: TextVersion
  let from: Provenance
  let declarations: Array[Declaration] val
  let references: Array[Reference] val
  let foldable: Array[SourceSpan] val
  let diagnostics: Array[Diagnostic val] val

  new val create(
    document': WorkspaceDocument,
    version': TextVersion,
    from': Provenance,
    declarations': Array[Declaration] val,
    references': Array[Reference] val,
    foldable': Array[SourceSpan] val,
    diagnostics': Array[Diagnostic val] val)

  fun declaration_at(version': TextVersion, pos: Position)
    : Answer[Declaration]
    """
    The declaration at `pos`. `version'` is the version `pos` is a position
    in; a mismatch against this document's version is `Superseded` rather
    than a confident answer about different text.
    """

  fun reference_at(version': TextVersion, pos: Position): Answer[Reference]
  fun definition_at(version': TextVersion, pos: Position): Answer[SourceSpan]
  fun enclosing(version': TextVersion, pos: Position)
    : Answer[Array[SourceSpan] val]
```

Every position-taking accessor takes the version its position belongs to. That
is invariant I5, and it is the one an earlier draft got wrong by stamping every
output and no input.

```pony
type Question is
  ( DeclarationOf   // (DefinitionRef)          -> Declaration
  | ReferencesTo    // (DefinitionRef, scope)   -> Array[SourceSpan] val
  | SubtypesOf      // (EntityPath)             -> Array[EntityPath] val
  | CallersOf       // (MemberPath)             -> Array[CallSite] val
  | CalleesOf       // (MemberPath)             -> Array[CallSite] val
  | MatchingSymbols )  // (String val)          -> Array[SymbolHit] val
  """
  Questions that span documents, and so cannot be answered from one
  document's pushed facts.
  """

interface tag AnswerNotify
  be answered(answer: Answer[Any val])
    """
    The payload type is erased here because a Pony behaviour cannot be
    generic per call site. The caller recovers it by matching on the
    concrete `Known[...]`, and a mismatched match compiles and takes the
    wrong branch. The alternative is one notify interface per payload type,
    six of them, which is the safer encoding and the larger surface.
    """
```

That erasure is a known hazard and is recorded rather than hidden. Six typed
interfaces is the safer choice and it is not obviously worth the surface; the
decision is deferred to whoever writes the pull half, which the first slice
does not.
### The seam, replaced

The existing seam is three functions wide and two of them are wrong for this
job:

```pony
trait tag LspCompiler
  be compile(package: FilePath, paths: Array[String val] val,
    notify: CompilerNotify tag)

interface CompilerNotify
  be done_compiling(package: FilePath,
    result: (Program val | Array[Error val] val), run: USize)
```

`(Program val | Array[Error val] val)` cannot express "a tree and some
errors". That is the normal state of a file being edited, and it is why one
syntax error currently costs every feature at once. `Program val` hands out an
AST whose nodes are raw `Pointer[_AST] val` with no back-reference to their
owner, and `PositionIndex val` stores one such pointer per node — values that
are `val` in Pony while pointing into memory libponyc will free.

The replacement:

```pony
trait tag FrontEnd
  """
  Answers questions about the Pony source in a workspace.
  """

  be apply_settings(settings: (Settings | None))
    """
    Provide settings to initialise or reconfigure the front end. `None`
    completes initialisation without changing anything.

    Changed settings bump the revision and mark every document stale.
    `defines` become `@define_userflag` and drive `ifdef`, and `ponypath`
    decides which packages resolve at all, so published facts describe a
    program the new settings no longer specify. Today
    `handle_did_change_configuration` applies settings and triggers no
    recompile, which is why `PackageNotIndexed` can tell a user to fix
    `PONYPATH` and fixing it changes nothing.
    """

  be set_text(document: WorkspaceDocument, text: String val)
    """
    Replace this document's text whole and assign it a new `TextVersion`.
    Inputs are never mutated in place.
    """

  be forget_text(document: WorkspaceDocument)
    """
    Drop this document's text and its analysis.
    """

  be file_changed_on_disk(document: WorkspaceDocument)
    """
    The file changed underneath us -- a branch switch, a `corral update`.
    Nothing else tells the front end this, and it cannot detect it.
    """

  be observe(workspace: FilePath, notify: AnalysisNotify tag)
    """
    Register for pushed analysis of one workspace. Keyed by workspace
    because one server runs several `WorkspaceManager`s over one front end.
    """

  be ask(question: Question, notify: AnswerNotify tag)
    """
    Ask a question that spans documents.
    """

interface AnalysisNotify
  be analysis_changed(document: WorkspaceDocument,
    analysis: DocumentAnalysis, facts: DocumentFacts val)
    """
    One document's analysis advanced. Pushed per document rather than as a
    workspace snapshot: a workspace value would be rebuilt whole per change.
    """

  be diagnostics_ready(document: WorkspaceDocument,
    version: TextVersion, depth: AnalysisDepth,
    diagnostics: Array[SourceDiagnostic val] val)
    """
    Diagnostics for one version of one document, at one depth. Each
    publication carries the complete set known at that depth -- replace
    semantics, not deltas.

    `SourceDiagnostic` carries a `SourceSpan`, not an `LspLocation`.
    pony-lsp's existing `Diagnostic` holds an `LspLocation`, which holds an
    `LspPositionRange`, built through `LspPosition.from_ast_pos` -- so
    reusing it would import LSP presentation vocabulary into the front end
    and carry bug 3's byte-versus-UTF-16 defect into a shared library. The
    conversion belongs on the pony-lsp side, with every other conversion to
    the wire.
    """
```

Four things changed and each fixes a named defect.

**Diagnostics travel alongside facts, never instead of them.** There is no
success-or-failure union. A file that does not typecheck still has an outline.

**The document key is a validated type.** `WorkspaceDocument val` is minted
once by the router from a URI — percent-decoded, canonicalised, and checked to
be inside the workspace — and is the only type `set_text`, `SourceSpan` and
`LocalDef` accept. `DocumentNotInWorkspace` becomes that constructor's failure
rather than an answer variant checked at sixteen call sites. It also bounds the
key space: a client cannot `set_text` arbitrarily many fabricated documents.

**`observe` is keyed by workspace.** `language_server.pony` creates one
`WorkspaceManager` per scanned Pony workspace, several per client folder,
sharing one compiler. The existing seam passes `notify` per request so results
route back; an unkeyed registration would send every manager everything.

**`file_changed_on_disk` exists because nothing else supplies it.**
`didChangeWatchedFiles` appears once in the tree, at
`test/message_handler.pony:311`, in the *test client's* declared capabilities.
The server registers only `didChangeConfiguration`. A `git checkout` changes
many files with no notification. Today that is masked because `did_open`
recompiles; under a memoizing engine it is a correctness hole, and it is the
one invalidation the engine cannot detect for itself. Branch switching is a
daily workflow and no earlier draft modelled it.

`FromCompilerRun[T]` is deleted. Its per-field run id is redundant — all five
fields are compared against the same id — and the staleness window its own
docstring documents disappears when one immutable value is replaced instead of
five. Diagnostics keep a separate lifecycle, because they arrive during a run
while facts arrive at the end.

### Push what is per-document, pull what spans documents

The line is drawn on **scope**, not on cost. A pushed value must be rebuilt to
be republished, so anything cross-document in it is rebuilt per change: a
reverse index for find-references maintained inside an immutable published
value costs, per keystroke, the size of every bucket the edited document
touches — and a popular bucket for `String` or `Array` holds thousands of
entries that a `val` array cannot extend. That is worse than having no index.

So:

- **Pushed, per document**: `DocumentFacts val` — declarations, references,
  foldable regions, diagnostics, and position lookups over them. Read
  synchronously by the feature layer with no round trip, which is what lets a
  feature decide *not* to ask.
- **Pulled, cross-document**: `declaration(id)`, `references_to(id, scope)`,
  `subtypes_of(id)`, `matching_symbols(query)`. Their indices live as `ref`
  state inside the front-end actor, rebuilt when a compile completes, never
  published.

`collections/persistent`'s `HashMap[K, V, H]` — `fun val update(key, value):
HashMap`, O(log n) with structural sharing — is what the per-document map uses.
A flat `val` map cannot be extended without an O(n) rebuild, and there are
thousands of declarations in a workspace. `pony-lsp` already imports
`collections/persistent`, though only for `Vec`.

### The invariants, and what enforces each

`FINDINGS.md` names three the engine rests on.

| Engine invariant | At the boundary | Enforced by |
|---|---|---|
| Inputs immutable, replaced whole | **Preserved and exposed.** `TextVersion` is its face | Type system: text enters only through `set_text`; there is no mutating entry point |
| Every derived value a pure function of its key | **Kept inside the engine, not imposed on the feature layer**, which does I/O | Not enforced at the boundary; the boundary must merely not undermine it |
| Identity is interning | **Deliberately broken.** Interned handles are memo-lifetime-scoped | Type system: boundary identities are name paths, which need no interning and survive a sibling's edit |

Five the boundary owns:

- **I1 — No answer crosses without its provenance.** *Type system:* there is no
  constructor for a bare fact.
- **I2 — Nothing crossing the boundary aliases memory the engine owns.**
  *Two checkable rules, not a capability:* no fact type contains a `Pointer[…]`
  or a `String` built by `from_cpointer`, and every string in a fact type comes
  from `copy_cstring` or `clone`. `val` denies Pony writes; it says nothing
  about who owns the bytes. `class val AST` is a raw pointer with no
  back-reference to its owning `Program`, and `Program._final` calls
  `@ast_free` — so `val` alone is not the guarantee an earlier draft claimed.
  This one is testable: build a `DocumentFacts val`, drop the `Program`, force
  collection, read every field.
- **I2a — No value crossing the boundary contains an actor reference.**
  *Checkable by inspection, and it must be checked.* An immutable object graph
  sent between actors is not traced — the whole `FileSyntax` → array →
  `ItemSyntax` publication is cheap regardless of size — **unless an actor
  appears somewhere beneath it, because actors must always be traced.** One
  `tag` on one fact type turns every publication into a graph walk.

  Verified clean for the types in this design: nothing in `ItemSyntax`,
  `FileSyntax`, `DocumentFacts`, `Declaration`, `Reference`, `SourceSpan`,
  `DefinitionRef` or `DocumentAnalysis` holds one. The one that looked
  suspicious is not: `FilePath` is `path: String` plus `caps: FileCaps`, and
  `FileAuth` and `AmbientAuth` are primitives, so `WorkspaceDocument` may hold
  a `FilePath`. The obvious way to break this later is to put a `Channel` or a
  notify `tag` on a fact type for convenience.

- **I3 — The engine never answers `Absent` to a question its depth cannot
  decide.** "There is nothing here" and "this depth cannot see it" are
  different claims. *Convention inside the engine*, and the invariant whose
  violation is invisible. Its operational form: **no internal resolver may
  return a bare collection or a bare `(T | None)`**, or the collapse re-enters
  at the first helper that returns `[]`. This is not hypothetical —
  `DefinitionResolver.resolve` returns `[]` both for "no definition" and for
  "could not work it out", and `_ResolveASTTarget` reads empty as *this node is
  its own definition*.
- **I4 — Depth is not monotonic.** A document that reached `Typed` can return
  to `Parsed` when memos are evicted. *Convention:* no consumer may cache "we
  got `Typed` once".
- **I5 — Every input that carries a position also carries the version it is a
  position in.** *Type system.* This is the one an earlier draft got wrong:
  every output was stamped and every input was not, so `declaration_at(pos)`
  took a buffer position, resolved it against an older tree, and returned a
  confident answer. A position without a version is the original bug with extra
  steps.

And one that must be stated over the workspace rather than one document:

- **I6 — A write feature refuses while *any* open document in the workspace is
  dirty.** Rename walks every module of every package from the last compile and
  emits LSP `changes`, which carry no version, so the client applies them
  verbatim. A rename originating in clean file A emits an edit for open, edited
  file B at compiled coordinates — splicing the new name into unrelated text,
  inside a single undo entry. Restricting the check to the originating document
  does not catch it.

### Consumer sketches

Written out rather than asserted to be consistent.

**Hover — per-feature stale policy, keeps content, drops range.**

```pony
  be hover(document_uri: String, request: RequestMessage val) =>
    """
    Handling the textDocument/hover request.
    """
    (let line, let column) =
      match \exhaustive\ this._parse_position(request)
      | (let l: I64, let c: I64) => (l, c)
      | None => return // Error already sent
      end
    match \exhaustive\ this._document(document_uri)
    | let doc: WorkspaceDocument =>
      let facts = this._facts(doc)
      // The version the client's position belongs to -- the text the
      // server currently holds -- not the version the facts describe.
      // Passing the facts' own version would make every check succeed and
      // `Superseded` unreachable, which is invariant I5 defeated by its
      // own call site.
      match \exhaustive\
        facts.declaration_at(this._version(doc), Position(line, column))
      | let k: Known[Declaration] =>
        this._channel.send(
          ResponseMessage(
            request.id,
            HoverResponse(
              HoverFormatter.render(k.value, k.from.depth),
              // The range is sent only when the span's own document is at
              // the version the client holds. LSP allows Hover.range to be
              // absent; a wrong range is worse than none.
              this._span_if_current(k.value.name_span))))
      | let a: Absent =>
        this._channel.send(ResponseMessage.create(request.id, None))
      | let u: Unavailable =>
        this._channel.log("hover unavailable: " + u.describe())
        this._channel.send(ResponseMessage.create(request.id, None))
      end
    | None =>
      this._channel.send(ResponseMessage.create(request.id, None))
    end
```

**Go to definition — same shape, refuses on a stale span.**

```pony
  be goto_definition(document_uri: String, request: RequestMessage val) =>
    """
    Handling the textDocument/definition request.
    """
    (let line, let column) =
      match \exhaustive\ this._parse_position(request)
      | (let l: I64, let c: I64) => (l, c)
      | None => return
      end
    match \exhaustive\ this._document(document_uri)
    | let doc: WorkspaceDocument =>
      let facts = this._facts(doc)
      match \exhaustive\
        facts.definition_at(this._version(doc), Position(line, column))
      | let k: Known[SourceSpan] =>
        // Unlike hover, the span IS the answer, so a stale one is refused
        // rather than degraded. A definition in an unedited file is current
        // even when the file the cursor sits in is not.
        match \exhaustive\ this._span_if_current(k.value)
        | let loc: LspLocation val =>
          this._channel.send(ResponseMessage(request.id, loc.to_json()))
        | None =>
          this._channel.send(ResponseMessage.create(request.id, None))
        end
      | let a: Absent =>
        this._channel.send(ResponseMessage.create(request.id, None))
      | let u: Unavailable =>
        this._channel.log("definition unavailable: " + u.describe())
        this._channel.send(ResponseMessage.create(request.id, None))
      end
    | None =>
      this._channel.send(ResponseMessage.create(request.id, None))
    end
```

Side by side the two are the same shape — resolve the document, ask the pushed
facts with a version, match three ways, send. They differ in exactly one place,
and the difference is the per-feature policy: hover degrades a stale span by
dropping it, go-to-definition refuses because the span is the answer. That
divergence is the price of the policy chosen over uniform refusal, and it is
stated here rather than hidden.

Both are synchronous, because both read pushed per-document facts. Only the
four cross-document features split into an ask and a reply. That is a
deliberate consequence of the push/pull line: **asynchrony is a real safety
regression** — nothing in the type system forces a reply to be sent, and a
forgotten reply hangs the client — so it is confined to the four features that
genuinely need it rather than imposed on all sixteen.

The three hang paths, and what bounds each: a forgotten reply is mitigated by
`notify` being a required parameter, so a call site that constructs no reply
object does not compile; `Superseded`'s "re-ask" is bounded **inside** the
boundary, which knows the current version, rather than exported to a caller
that does not; and `WorkspaceSymbolAggregator` completes on a count, so its
contributions are `Answer`-typed and an `Unavailable` still counts.

### All sixteen features

Depth is stated per referent where a feature spans more than one.

| Feature | Question | Depth | Stale policy |
|---|---|---|---|
| Document symbols | `outline(doc)` | `Parsed` | serve |
| Folding range | `foldable(doc)` | `Parsed` | serve |
| Selection range | `enclosing(doc, pos)` | `Parsed` | serve |
| Syntax diagnostics | pushed | `Parsed` | serve |
| Workspace symbols | `matching_symbols(q)` | `Bound` | serve |
| Hover — declaration | `declaration_at` | `Bound` | serve, drop range |
| Hover — inferred type line | `declaration_at` | `Typed` | serve, drop range |
| Go to definition / declaration | `definition_at` | `Bound` for locals, params, type and package names; `Typed` for method calls and field accesses | refuse |
| Go to type definition | `type_of` then `definition` | `Typed` | refuse |
| Document highlight | `references_to(id, this doc)` | as go-to-definition | refuse |
| Find references | `references_to(id, workspace)` | as above, plus a reverse index | refuse |
| Rename | references + validity | as above | **refuse while any open doc is dirty** |
| Signature help | `signature_at(doc, pos)` | `Bound` names, `Typed` parameter types | serve, drop active-parameter highlight |
| Call hierarchy | `callers_of` / `callees_of` | `Typed` — a call's target needs the receiver's type | refuse |
| Type hierarchy — supertypes | `supertypes_of` | `Bound` — a provides list is written | refuse |
| Type hierarchy — subtypes | `subtypes_of` | `Typed`, plus a reverse index | refuse |
| Inlay hints | `inferred_types_in(doc, range)` | `Typed` | **suppress** rather than sit on wrong lines |
| Semantic diagnostics | pushed | `Typed` | serve |

Eighteen rows for sixteen features, because hover, go-to-definition, type
hierarchy and diagnostics each split by referent. That split is the point.

Two protocol pairs must migrate together, and this is an invariant rather than
advice: `prepareRename`/`rename`, `prepareCallHierarchy`/`incomingCalls`,
`prepareTypeHierarchy`/`supertypes`. Migrating a `prepare` alone produces a
rename box that opens with the symbol selected, accepts the new name, and then
answers a **successful null** — nothing happens, no error, no message. The
`prepare` half also stops round-tripping a position through `item.data` and
carries a `MemberPath` instead, which fixes the existing resolve-by-position
bug in the same change.

Semantic tokens is named and refused. It needs every token with a
classification, which is bulk per-token data; `DeclarationFacts` cannot express
it and must not stretch to. When it is wanted the answer is a separate question
returning `Array[U32] val` — bare integers, no wrapper per token.

## Question 2 — what plays salsa's part

### The minimum for the LSP case

| salsa mechanism | Needed? |
|---|---|
| Inputs with revisions | Yes. This is `set_text` |
| Memoized derived queries | Yes — the product |
| Dependency tracking | Yes |
| Backdating — an unchanged result does not re-run dependents | **Yes, and it is the cheapest large win.** It is what made a `//` comment edit cost 1 query out of 20937 |
| Cycle handling with initial values | **Only once subtyping exists.** `FINDINGS.md` reports exactly one inherent cycle, `is_subtype` coinduction, reached constantly; the other four are defensive and the standard library reaches none. A slice below subtyping needs none of this machinery |
| Interning | For memo keys — but see below on whether a central table is needed |
| Accumulators for diagnostics | **Probably not.** salsa needs them because a query whose result is interned cannot also carry a diagnostic list. A query returning a plain struct carries its diagnostics as a field |

### A separate package, in the same repository

The engine — inputs, revisions, memoization, dependency tracking, backdating,
cycles — mentions nothing about Pony the language. The front end does. Keep them
as two packages with the engine depending on nothing, in one repository. Split
repositories only if a second consumer appears; a generic engine with exactly
one consumer is the indirection the skeptic's rule warns about, and one
repository keeps the option open at no cost.

### The memo store, where no Rust measurement decides it

`ponyq`'s ceiling comes from a shared **mutable** interning table: salsa takes a
shard mutex to *read*, an uncontended mutex is still a store, so an interned
read is a write to a line every core is also writing. `xsnp_hitm` rises by three
orders of magnitude from 1 to 32 threads. **Pony cannot build that design**, so
the failure mode does not travel and what replaces it is unmeasured.

Four candidates:

**A. One engine actor owns everything.** Every query is a behaviour call.
Trivially correct, no interning contention, no snapshots, serial. `FINDINGS.md`
puts the hard parallel ceiling for the standard library at 20x from work
granularity alone and measures 4.5-6.3x. For a single request the LSP is
latency-bound, not throughput-bound. **This is the honest baseline anything more
complicated must beat**, and it may simply be enough.

**B. Engine actor owns a `ref` table, publishes `val` snapshots.** Readers hold
a snapshot and read it with no lock and no store — the thing `ponyq` could not
have. A miss against a stale snapshot costs an actor round trip and a causal
wait. The obvious shape; the open question is what the miss costs and how often
it happens.

**C. Readers intern locally and reconcile.** This one can silently break the
property the whole design rests on. If reader R interns type T against snapshot
S and allocates id `k` while the owner allocates `j` for the same T, R's memo
entries keyed on `k` are not comparable with the owner's keyed on `j` — and
"two structurally equal types get the same key", which is what makes
`is_subtype` memoizable at all, is gone. Reconciliation needs provisional ids
remapped on publish, or:

**D. Content-addressed identity — no central allocator.** If a type's id is a
strong structural hash rather than a counter, two workers derive the same id for
the same type without communicating, and interning stops being a coordination
mechanism at all. It becomes storage deduplication, which can be local, lossy,
or skipped. This removes C's reconciliation question and B's publish question
for keys. Costs: a structural hash per constructed type — bottom-up, cacheable
in the value, so O(1) amortised — and collision risk, which needs 128 bits or a
detection table and a written answer for what happens on one.

D is not in `FINDINGS.md`. It is the option that most directly exploits Pony
forcing immutability where salsa merely allows it, and on correctness grounds it
should be preferred before performance is considered at all.

### What the Rust numbers do and do not decide

**They constrain:** the pointer-depth half of the persistent-map 38% —
`FINDINGS.md` says itself that the HAMT chasing "survives any language" while
the `Arc` half does not; file-granularity invalidation, 8.1% for a body edit
and 33% for `builtin/array.pony`; 248 MB per stdlib check with no eviction
policy ever tested; and "do not memoize what is cheaper to recompute".

**They do not constrain:** the 4.5-6.3x ceiling and the entire `xsnp_hitm`
story, whose cause is a construction Pony cannot express; "sharing nothing buys
19%", which is batch throughput rather than request latency; the `Arc` half of
the 38%; and the `ast_of`/`NodeRef` counts, which measure positional identity
that this design rejects.

**And they do not touch the write side at all.** `FINDINGS.md` priced reads and
never priced publish. In Pony that is the decisive cost: a flat `val` map cannot
be extended, so publishing a new version means rebuilding it, O(n) per insert
at tens of thousands of entries. A persistent map extends in O(log n) with
sharing and does not pay `im`'s per-node `Arc` because a traced `val` is not
refcounted per access. **The Rust conclusion — "persistent is the wrong reason
to want lock-free reads" — does not transfer, because it never priced the thing
that decides it in Pony.**

### The measurement to take before committing

One benchmark, no front end required, at realistic size — 20937 memo entries for
a cold `collections` check, 243357 interned keys:

1. **Publish cost.** Rebuilding a flat `val` `HashMap` versus
   `persistent.HashMap.update`, per insert and per batch of 100 and 1000.
2. **Hit latency.** Flat `val` map read from a snapshot; `persistent.HashMap`
   read from a snapshot; a behaviour call to an actor owning a `ref` map.
3. **Miss against a stale snapshot.** The round trip in B, and how often a miss
   actually occurs — which needs an edit trace replayed, not a guessed hit rate.
4. **Structural hash cost** for D, with and without caching the hash in the
   value.

**Take 1 first.** It is the cheapest, it is the one no Rust number speaks to,
and it is the one most likely to eliminate an option outright. If publish
dominates, B collapses into the persistent variant regardless of read cost. If
2 shows the actor round trip within a small factor of a snapshot read, A wins on
simplicity and nothing further is needed for years. If 4 is cheap, D removes the
reconciliation question entirely.

### What the measurement said

`tools/memo_bench` and `tools/actor_latency`, at 20937 entries:

| | flat `val` map | `collections/persistent` |
|---|---|---|
| publish 1 entry | 2,773,046 ns | 664 ns |
| publish 1000 | 2,818,722 ns | 804,058 ns |
| build all from cold | 1,992,868 ns | 15,237,581 ns |
| hit | 145 ns | 347 ns |

Actor round trip 707 ns; pipelined 221 ns.

**B with a persistent map.** Three things decided it:

`concat` is a loop of `update`, not a bulk path — 1000 entries cost the same
either way — so no second representation is bought by using one for cold
builds and the other for edits. Since one representation has to serve both,
the 13 ms extra on a cold build is the price, and it is noise beside a cold
check that takes seconds. The 4,000x on an incremental publish is the case
that happens on every keystroke.

**The decision rule above fires for A, and the rule was measuring the wrong
thing.** 707 ns against 347 ns is a small factor. But the rule assumes the
round trip is paid per query, and it is not: under A the checker runs inside
the owning actor, so recursive queries are direct calls on `ref` state and the
round trip is paid once per language server request, which is already
asynchronous. A's latency cost is nil. Its real cost is that it serialises —
while a cold check runs, the actor answers nothing — and that is the blockage
this work exists to remove. Read latency did not decide this; blocking did.

**The persistent map is for the published snapshot, not for the engine.** The
revision counter and dependency graph live inside one actor and are never
shared, so they are plain mutable arrays. `Engine` holds no results at all:
dependencies cross query kinds, so the graph has to be homogeneous, and a
graph over heterogeneous typed values would have to be a graph over `Any`.
Results stay in the caller's typed tables and the caller interns its own keys,
which is also the only place that knows when two Pony types are structurally
equal.

Measurements 3 and 4 were not taken. A reader miss is not a performance
question in this shape — it means "not computed at this revision yet", which
is the `NotYetKnown` protocol above. The structural hash only matters if
several workers intern at once, which nothing does yet.

## Question 3 — whether any of libponyc is kept

**No. Write the lexer and parser in Pony, error-tolerant and lossless from the
start.** libponyc's parser is kept only as the semantic back end during
migration, and only until the front end reaches its depth.

The brief framed this as transcribe versus reuse. Both answers were wrong for
the same reason: they assumed the parser we want is the parser ponyc has.

### Why reuse fails, and why a faithful transcription fails with it

libponyc's parser has no error recovery. `parserapi.c` frees the entire tree
and returns false if the error count rose during the parse — one unclosed paren
and there is no tree at all. `RESTART` exists in both ponyc and ponyq, but it
is a resync that lets the parser report *further* syntax errors, not a
tree-building recovery: ponyq's own `parser_api.rs` says a rule that
"recovered at a restart point reports [NoAst], exactly as ponyc's parserapi
returns NULL for both".

That is correct for a batch compiler, which is entitled to stop at the first
error. It is wrong for a language server, because a buffer is syntactically
invalid most of the moments it is observed. **A transcription of that parser
inherits the defect**, which is why `ponyq` has it too — it never needed
otherwise.

libponyc's AST is also lossy: it carries no whitespace and no comments. That is
why `pony-lint` hands every one of its 34 AST rules the raw `SourceFile`
alongside the node, and why pony-lsp's `InlayHintSource` scans source bytes to
answer "was the capability written?". Losslessness and error tolerance are the
same property from two directions — a parser that keeps what it could not
interpret is a parser that keeps everything — so they are one decision.

### What is actually being ported

**The grammar is a 1:1 transcription that has already been done twice.**
`parser.c` defines 129 rules. ponyq's `parser.rs` defines exactly 129, kept
deliberately diffable against the C. Those rules call a runtime of about twenty
functions — `token`, `skip`, `terminate`, `rule`, `seq`, `iff`, `ifelse`,
`whilee`, `ast_node`, `done`, `scope`, `restart`, `reorder`, `set_flag`,
`infix_build`. **The rules are the expensive, twice-validated part; the runtime
is the small separable piece that decides what happens on error.**

So this is not "write a Pony parser". It is: port 129 known-good rules against
a runtime that never fails. That is also how rust-analyzer is built — its
grammar calls `expect`, `bump` and `error`, and the runtime decides what tree
comes out.

FINDINGS records that ponyq's AST is byte-identical to ponyc's across all 350
test directories, and its syntax errors byte-identical too. That is the
correctness bar for the port, and it is checkable the same way.

Budget, honestly: ponyq's lexer and parser are 3,401 Rust lines (`lex.rs` 931,
`parser.rs` 1,191, `parser_api.rs` 774, `token.rs` 446, `lexint.rs` 59). Pony
is more verbose than Rust for table-driven code, and the tree infrastructure
and trivia handling are new. Budget **5,000-7,000 lines** for the complete
parser package, of which the first slice builds roughly half.

Carry one ponyq result into the port: the parser's cost was one line. Every
`TOKEN`, `SKIP`, `IF` and `WHILE` eagerly computed a description used only when
writing a syntax error — a linear scan of 210 name-table entries per token.
Making it lazy took a 113 KB file from 99.7ms to 22.4ms, 4.5x, putting the
parser ahead of ponyc's own throughput. A faithful port copies the defect.

### The tree: pre-order element arrays, widths not offsets

```pony
primitive TkClassKw    // the `class` keyword token
primitive TkId
primitive TkWhitespace
primitive TkClassDef   // the class node
primitive TkMembers
// ...one per ponyc token id, plus Whitespace, LineComment,
// NestedComment and Error, with node kinds and token kinds kept
// disjoint rather than reusing one id for both as ponyc does.
type TkKind is (TkClassKw | TkId | TkWhitespace | TkClassDef | ...)

class val ItemSyntax
  """
  One top-level declaration and everything inside it, flattened into a
  single pre-order array. The unit of structural sharing: an edit inside
  one item leaves every other item object untouched.
  """
  var width: U32
    """Bytes this item spans. A width, never an offset."""

  embed elems: Array[(TkKind, U32, U32)]
    """
    Pre-order. For each element: its kind, its width in bytes, and a third
    field whose meaning follows from the kind -- for a token, the index of
    its text in the intern table, zero for the ~62% whose text is fully
    determined by their kind; for a node, the size of its subtree in
    elements.

    Children of element `i` begin at `i + 1`; the next sibling of a node is
    at `i + size`. There is no parent link: a walk carries its own path.
    """

class val FileSyntax
  let text: String val
  let items: Array[ItemSyntax val] val
```

**Widths, never offsets.** This is the point, and it is the direct fix for what
FINDINGS names as the central flaw — "`parse(file)` returns one arena and every
node id in it shifts when the file changes", which is where its 33% re-check
figure comes from. An element that records its width and not its position is
unchanged by an edit anywhere outside it, so an edit rewrites one item and
nothing else. That subsumes the item tree FINDINGS recommends rather than
needing one built on top.

Positions are derived by a cursor that walks down carrying a running offset,
and `LineIndex` — built per text version by one scan — owns every conversion
between a byte offset and an LSP `(line, character)`. **That is the only place
in the system that knows the negotiated `positionEncoding`**, which is where
bug 3 gets fixed rather than propagated.

Two Pony properties make this cheap, and they are why the structure is arrays
of tuples rather than a node class per element. An `Array` of tuples stores the
tuples inline, so an element costs no allocation of its own; and `embed` inlines
the `Array` object itself into `ItemSyntax`, so an item is two allocations
total — the object and its data chunk. A union of primitives is a pointer to a
singleton, so `TkKind` carries its own identity and a `match` on it is checked
for exhaustiveness, where a packed integer tag would not be.

Measured against the real corpus — 2.19 MB of standard library, 369,703
non-trivia tokens, 637,773 ponyc AST nodes, so roughly a million tree elements
once trivia is retained, across 2,190 top-level items — that is **about 16 MB
and about 4,400 allocations for the whole standard library**, with a subtree
walk being a linear scan of contiguous memory.

### Error tolerance

The runtime never returns "no tree". Where a rule cannot match, it produces an
`Error` node containing the tokens it could not interpret and continues at the
rule's `RESTART` set. Every byte of input appears in the tree exactly once,
whatever happened, which is what makes the tree lossless and what makes
"reprint the tree, get the source back" a test rather than an aspiration.

Two properties follow that the first slice should assert:

- **Round-trip**: concatenating every `GreenToken.text` in order reproduces the
  input byte for byte, for every file in `packages/` and for arbitrarily
  corrupted versions of them.
- **Agreement**: with `Error` nodes and trivia stripped, the tree matches what
  ponyc's parser produces for every file ponyc accepts. This is ponyq's
  byte-identical bar, and it is what stops the port drifting from the language.

### What libponyc is still used for

Everything below the parse. The front end gets its names, types and diagnostics
from `pony_compiler` exactly as pony-lsp does today, until the query engine
reaches each depth. **The parse is replaced first because it is the layer where
error tolerance and losslessness live, and because it is the only layer that
can answer about a buffer that does not compile.**

Per-item source splitting — measured earlier in this work and effective — is
now unnecessary. It was a way to get error isolation out of a parser that
cannot recover. A parser that recovers gives isolation *within* an item too,
which per-item splitting never could. The probe stays in the repository as
evidence for the fallback, not as part of the plan.

## Question 4 — the smallest useful increment

**A lossless, error-tolerant Pony parser, and the four features that need
nothing but syntax — answered on every keystroke against the unsaved buffer.**

This is what the brief originally asked for and what libponyc could not
support. An error-tolerant parser is precisely the missing piece: the reason
unsaved-buffer freshness was dropped from an earlier version of this slice was
that a buffer being typed does not parse, and libponyc's parser yields nothing
when it does not parse. A parser that always yields a tree removes the
obstacle.

### What gets built

**The lexer**, ported from ponyq's `lex.rs`, with one change: trivia are
retained. Whitespace, line comments and nested comments become tokens with
their exact text rather than being skipped. Everything else — the numeric
literal machinery in `lexint`, string and character literals, the keyword
tables — ports as it stands.

**The tree** as specified in question 3, plus `LineIndex` for
offset-to-position conversion.

**The runtime**, which is the new work rather than a port: the twenty-odd
functions the grammar rules call, reimplemented so that no rule can fail.
Where ponyq's returns `Error` or `NotFound` and unwinds, this one emits an
`Error` node holding the tokens it could not interpret and resynchronises at
the rule's `RESTART` set.

**About 64 of the 129 grammar rules** — `module`, `use`, `use_uri`, `use_ffi`,
`use_name`, `class_def`, `members`, `method`, `field`, `params`, `param`,
`typeparams`, `typeparam`, `typeargs`, `provides`, `defaultarg`, and the entire
type grammar (`type`, `nominal`, `uniontype`, `isecttype`, `infixtype`,
`tupletype`, `groupedtype`, `thistype`, `typelist`, `lambdatype`,
`barelambdatype`, `atomtype`, `viewpoint`, `cap`, `gencap`, `bare`).

**Method bodies as a block skeleton.** One rule that consumes a body by
tracking Pony's keyword-delimited blocks — `if`/`while`/`for`/`try`/`match`/
`recover`/`object` against `end`, plus bracket pairs — emitting `Block` nodes
around balanced regions and token runs between them. It is a real nesting
structure, which is what folding and selection range need, and it is a single
rule that the 65 expression rules replace later without touching anything
else.

### What pony-lsp gets

- `textDocumentSync.change` becomes `1`, `didChange` is handled, and the buffer
  is parsed on every change. Parsing one file is 3-40ms depending on size, so
  no debounce is needed at this stage.
- **Document symbols, folding range, selection range and syntax diagnostics
  answer from the buffer**, at `Parsed` depth, fresh on every keystroke,
  including while the file does not compile and while it does not parse.
- The other twelve features keep answering through `pony_compiler` exactly as
  today, at `Typed` depth, stamped with the version they describe. Nothing
  regresses.
- The stale-policy table becomes live rather than theoretical, because for the
  first time a document can be dirty and the server knows it.

### The boundary, at this depth

`DocumentFacts` is projected from the syntax tree rather than from a libponyc
module. `FactsFromModule` still exists for the `Typed` depth during migration;
`FactsFromTree` is the new producer, and the two must agree on `DefinitionRef`
construction — that agreement is the first slice's sharpest test, because it is
what lets a feature move from one producer to the other without changing what
the user sees.

The three layers this settles:

- **The parser package** owns the tree. No LSP vocabulary, no facts, no
  `pony_compiler` dependency. This is what `pony-lint` would consume.
- **The front end** projects facts from the tree, and from libponyc below its
  current depth. This is what pony-lsp consumes.
- **pony-lsp** owns JSON, markdown, and the protocol.

### Tests, and what makes this slice falsifiable

Two properties assert themselves against a corpus that already exists:

- **Round-trip.** Concatenating every token's text reproduces the input byte
  for byte, over all 255 files in `packages/` — and over corrupted versions of
  them, which is the property that matters, since that is the state the parser
  exists to handle. Generate corruptions by truncation, by deleting a random
  byte, and by inserting an unbalanced delimiter.
- **Agreement with ponyc.** With trivia and `Error` nodes stripped, the tree
  matches what ponyc produces for every file ponyc accepts, and the syntax
  errors match too. This is exactly ponyq's bar — byte-identical across 350
  directories — and it is what stops the port drifting from the language.

`pony_test` covers both, and the existing 12,646-line LSP suite covers the four
migrated features at the protocol level. `_LspTestServer` needs `did_change`
and real document text in `_did_open`, which it does not have today.

The property tests are worth more here than anywhere else in this design, and
`pony-pbt-patterns` is the right guide for the corruption generators.

### Scale, honestly

Roughly half the parser package: the lexer, the tree, the runtime, 64 rules and
the skeleton. Call it **3,000-4,000 lines of Pony**, plus the LSP-side wiring
and the fixture work. That is **six to ten weeks** at a normal pace, and the
first four or five of those produce nothing a user can see, because the tree
and the runtime come before any rule does.

If that is too long to go dark, the sequencing that shortens the first visible
result is: lexer and tree first with round-trip tests, then syntax diagnostics
alone — which needs the runtime but almost no grammar, because an `Error` node
*is* a syntax diagnostic — then the item rules, then the skeleton. Syntax
diagnostics on an unsaved buffer is a visible, shippable capability that
pony-lsp does not have today and it arrives well before the outline does.

### What is deliberately not in it

The 65 expression and statement rules. Incremental reparse — the tree
makes it possible, but a full reparse of one file is milliseconds and the
machinery to find the smallest reparsable node is work with no user-visible
return at this size. Any query engine: `DocumentFacts` at `Parsed` depth is a
pure function of the tree, so nothing needs memoizing yet. And every semantic
depth, which continues to come from libponyc.

## Question 5 — where the package lives

**`ponyc/tools/lib/ponylang/`, alongside `pony_compiler`.**

- It is the established home for a shared tool library, and `pony_compiler`
  already has two consumers: pony-lsp and pony-lint, both wired through
  `add_pony_binary` with `PATHS` pointing at that directory.
- Anything reusing libponyc through FFI must link `ponyc-standalone` and be
  built by ponyc's CMake, which settles it for the first slice.
- **No external corral dependency is used anywhere in the ponyc tree.**
  `tools/corral.json`'s own description says it "is only there for helping the
  pony-lsp to find its deps", and its single dep is the local
  `./lib/ponylang/pony_compiler`. A design needing an external dependency is a
  design that does not fit where it is going — which is one more reason nothing
  here uses one.
- pony-lsp ships co-installed with ponyc via ponyup, so versions cannot drift.
  Shipping the front end separately would reintroduce exactly the drift the
  co-installed layout prevents.

**Designed for pony-lint, migrated later.** The parser package carries no LSP
vocabulary and no `pony_compiler` dependency, so pony-lint can adopt the tree
when someone wants it — and a lossless tree is precisely what it needs.
`ASTRule.check(node, source)` hands every one of its 34 rules the raw
`SourceFile` alongside the node, and `operator_spacing.pony` indexes
`source.lines` at the node position, because the libponyc AST carries no
whitespace. A tree that holds every byte removes that workaround. pony-lint
already models the depth axis too: `ASTRule.required_pass()` returns
`PassParse` for syntax-only rules and `PassExpr` for rules needing types.

Nothing blocks on it. The cost of keeping the option open is a rule already in
force — no LSP types below the top layer — and pony-lint's maintainers have not
been asked, which is the cheapest way to settle whether it is wanted.

## Bugs found while designing

Verified against the source. All three are live in shipped pony-lsp,
independent of this design, and all three are small.

**1. Two hashes over different byte counts, so the staleness check never
matches.** `Module._hash = @ponyint_hash_block(source.m, len)`
(`pony_compiler/module.pony:32`) where `source.c:50` sets
`source->len = size + 1` — including the NUL terminator. `String.hash()` is the
same function over `_size` (`packages/builtin/string.pony:1663`) — without it.
Identical text hashes differently. Live at `workspace_manager.pony:424` versus
`:175-189`, where a saved document's `text.hash()` is compared `!=` against
`module_hash()` to decide `requires_another_compilation`: always unequal,
always yes. Today it costs a redundant compile. Found independently by three
evaluation personas.

Note for the design: an earlier candidate used `Module.eq` — file plus content
hash — as the clean-versus-dirty discriminator. Built on this, it would report
"different" forever and every un-migrated feature would go silent for the whole
session, on files never edited. This design discriminates on a server-assigned
version instead, which is exact and needs no agreement about terminators.

**2. The re-compile trigger compares a filename against a directory.**
`workspace_manager.pony:172`: `Path.base(await_comp_file)` yields `list.pony`;
`package_state.path.path` is a directory. Never equal, so the body never runs —
`_awaiting_compilation_for` entries are never removed and
`requires_another_compilation` is never set. A `didSave` or `didOpen` arriving
while a compile is in flight is recorded and then never acted on. `Path.dir`
was presumably meant.

**3. Byte columns are reported as UTF-16 code units.**
`LspPosition.from_ast_pos` (`position.pony:44`) passes `position.column() - 1`
straight through. libponyc counts bytes: `lexer->pos += count` at
`lexer.c:419`, reset on newline at `:414`. LSP 3.17 defaults `positionEncoding`
to `utf-16` when the server declares none, and the server declares none — the
only occurrence in the tree is the *test client's* capabilities at
`test/message_handler.pony:311`.

On any line with a non-ASCII character before the symbol — a typographic quote
in a docstring, an accented identifier, an em dash in a comment — every reported
column is off by the extra UTF-8 bytes. Hover and highlight land wrong, which
is cosmetic. `workspace/rename.pony` returns `TextEdit` ranges the client
applies verbatim, which is not: a range off by two bytes does not fail, it
edits the wrong characters. **Not confirmed with a fixture** — the reasoning is
from the two code paths and the spec default, and it deserves ten minutes
before filing. Declaring `"positionEncoding": "utf-8"` makes the existing byte
columns correct for clients that support it; a conversion at the boundary is
the complete fix, and this boundary is where AST positions become client
positions, so it is the right place for it.

Two smaller things, recorded without a recommendation:
`DocumentState._document_symbols` is written and never read —
`fun ref document_symbols()` rebuilds unconditionally and overwrites the cache.
And `DefinitionResolver.resolve` returns `[]` both for "there is no definition"
and for "I could not work it out", after which `_ResolveASTTarget` reads empty
as *this node is its own definition* — so an unresolvable call site is treated
as a declaration and rename would offer to rename it. Whether the failing
branch is reachable on a well-typed program is unverified; it stops being
latent under any tiered design, because below full type checking that branch
becomes the common case. This is the concrete argument for invariant I3.

## What is uncertain

Ordered by how much damage being wrong would do. Six entries from an earlier
draft have been resolved and are recorded as such, because a design document
that only grows its uncertainty list is not being read.

**2. Whether `FactsFromTree` and `FactsFromModule` can be made to agree.** Two
producers of the same fact types during migration, and the whole per-feature
migration rests on a feature moving from one to the other without the user
seeing a change. `DefinitionRef` construction is where they must agree exactly.
This is the first slice's sharpest test and it has no precedent to copy.

**3. `FactsFromModule` is unpriced and is the highest-leverage item.** It is the
only new O(workspace) computation: projecting every declaration in every module
into fact values, eagerly at each rung — and eagerly is now required rather than
preferred, because lazy projection reads a tree `expr` has rewritten. Three
rungs means three projections. If it runs on the actor that assembles the push,
requests queue behind it, which is the argument this design makes about
`PonyCompiler` and must not repeat one layer up. Measure before building.

**4. What `Parsed` means with respect to desugaring.** "Syntax only" reads as
`PassParse`, but the folding-range tests document that they assert around
ponyc's desugaring — `object` and lambda literals become synthetic classes after
`expr`, `with` desugars before the typechecked AST so `tk_with` never appears,
and fixtures give structs and actors explicit constructors so ponyc does not
synthesise ones that would appear as extra ranges. `symbols.pony` filters
synthesized constructors and `add_comparable`'s `eq`/`ne`, and three tests
guarding those filters would become vacuous at a pre-sugar tier — passing, and
no longer able to fail.

There is a user-visible consequence beyond the fixtures: **the outline changes
shape between rungs**, because `ast_replace` turns an `object` literal into a
synthetic class during `expr`. A document symbol tree that re-renders on the
way from `Parsed` to `Typed` is a flicker the user sees. Pin what `Parsed`
means in its docstring, and decide whether the shallow outline suppresses
constructs it knows will change.

**5. Whether `EntityPath.package` is unique enough.** It uses the qualified
name. `package_hygienic_id` exists in libponyc because qualified names are not
unique, and `WorkspaceManager._packages` is keyed by path. This design's
identity may be *less* discriminating than the code it replaces. Not traced.

**6. Resource bounds.** Nothing here bounds text size, and libponyc's parser is
recursive descent with no depth limit — `parserapi.h:52-56` says so — so a
deeply nested expression in a repository the developer did not write overflows
the C stack and takes the process down. `source_open` reads a whole file into
one allocation with no size check. Both are pre-existing and neither is created
here, but a whole-workspace parse turns one hostile file from "breaks the
package you opened" into "breaks the session". A size cap surfaced as a fact
rather than a crash belongs in the front end; the depth limit belongs in
libponyc.

**7. Whether stale-but-stamped is what users want.** The per-feature policy
trades a uniform auditable rule for sixteen small ones. It can only be settled
by using it.

**8. Whether `NotYetKnown`'s retry contract is honourable on the synchronous
path.** Twelve features read pushed facts and reply immediately; both written
sketches send `null`, which is a *successful* LSP response that no client
retries. With the parser answering at `Parsed` while libponyc answers at
`Typed`, "not yet at this depth" is the ordinary state for a freshly typed
buffer rather than a rarity. Either the synchronous path
waits, bounded, or it does not promise a retry.

### Resolved since the first draft

- **Does the tree give folding and selection range what they need?** Yes, and
  the question stopped being about a skeleton: the expression rules are ported,
  so a fold is an `NdIf` or an `NdWhile` rather than a counted region. The
  existing folding and selection fixtures pass unchanged, which is what
  `SiblingBound` was the worry about.
- **Does per-item parsing work?** Yes — measured, not reasoned about:
  positions exact, a broken item costs only itself, 2,159 of 2,190 stdlib items
  parse alone, no measurable cost. It is no longer part of the plan, because a
  recovering parser gives isolation *within* an item too, which splitting never
  could. It stands as the fallback if the Pony parser is deferred, and the
  probe is kept for that reason.
- **Does `continue_to` leave a readable tree after a failure?** For memory,
  yes; for content, no — `ast_pass_record` flags the root even on the error
  path, so a retry at the same limit short-circuits and returns `true` over a
  partially typed tree. Recorded because it still governs any staged use of
  libponyc as the semantic back end, which the migration relies on.
- **Does `codegen_pass_init` do process-global LLVM setup?** No; that is
  `codegen_llvm_init`, which `pony_compiler` never calls.
- **Does publishing a tree to reader actors cost a deep trace?** No. An
  immutable graph sent between actors is not traced, so the size of the
  publication does not matter — provided no actor reference hides inside it.
  That condition is now invariant I2a rather than an assumption.
- **What does the tree cost in Pony?** About 16 MB and 4,400 allocations for
  the whole standard library, because an `Array` of tuples stores its elements
  inline and `embed` inlines the array object into the item. Two allocations
  per top-level item. It was on this list as the largest unmeasured risk; it is
  not a risk.
- **Can two actors call libponyc concurrently?** Yes, given one `pass_opt` each
  and no sharing. Audited; the evidence is in question 3.

## What is wired to the buffer

Seven of the eighteen rows above are answered from the buffer rather than
from the last compile, and need no compile at all:

| Feature | From |
|---|---|
| Document symbols, folding, selection range, syntax diagnostics | `pony_analysis` |
| Workspace symbols | `pony_bind.matching` |
| Go to definition / declaration -- locals, parameters, fields, type parameters | `pony_bind.resolve_at` |
| Go to definition / declaration -- types the workspace declares | `pony_bind.resolve_at` |

Go to definition tries the buffer first and falls through to the compiler
for what needs a receiver's type. So it answers while typing where it can,
and still refuses -- rather than guessing -- where only the compile knows.

The workspace's own packages are read; a `use` reaching the standard library
still resolves through the compiler, because the search paths live in the
compiler actor and plumbing them out is its own change.

Migrating these changed two ranges the compiler had been giving, and the
change was taken deliberately rather than worked around. A type parameter's
declaration is one character, where libponyc's span ran on past it; and a
field's range is the whole declaration, where libponyc stopped at the type
for `var` and `let` and after the `=` for `embed`. The protocol asks for the
range enclosing the symbol, so the three now agree.

## Future work, written down rather than built

- ~~**The 65 expression and statement rules**~~ — done. They landed as
  addition rather than rework, as expected: the runtime did not change, and the
  item and type rules changed only where they had called the skeleton. What was
  not expected is that they made the parser hang, on ponyc's own annotation
  fixtures. A rule that consumes nothing must not be repeated, and the sequence
  loop now says so. `tools/agreement/README.md` has the account.
- **Incremental reparse.** The tree makes it possible: find the smallest
  node covering an edit and reparse only that. A full reparse of one file is
  3-40ms, so this has no user-visible return at current sizes and should wait
  until something measures a need.
- **Migrating pony-lint onto the tree**, once someone asks for it.
- ~~**The query engine proper**~~ — built, less cycle handling, which waits for
  subtyping to need it. `pony_query` is 282 lines and depends on nothing but
  `builtin`. Cycle handling is still future work.
- **An item tree addressed by name path**, which `FINDINGS.md` identifies as the
  largest available win, fixing invalidation granularity and key interning at
  once. This design takes the name-path *identity* half; the addressing half —
  item-relative spans, so an edit inside one item leaves every other item's
  facts bit-identical and shareable — is deferred and should be stated as
  deferred, because a reader seeing `EntityPath` will assume otherwise.
- **Completion.** Not currently advertised, and the one feature invoked while
  the buffer is definitionally invalid — mid-identifier, after a bare `.`. It
  needs freshness most and is served worst by every policy here. Worth modelling
  as a design exercise before it is wanted, because its answer is the honest
  statement of what a buffer tier is for.
- **Semantic tokens**, as a separate question returning `Array[U32] val`.
- **Incremental text sync** (`textDocumentSync.change = 2`). A `set_text`
  implementation detail, not a boundary change — but note that applying UTF-16
  range edits is where bug 3 would corrupt the server's own copy of the text
  rather than only a reported range.
- **`$/cancelRequest`.** Unhandled today, and the mirror of the forgotten-reply
  hazard: a reply arriving after the user moved on.
