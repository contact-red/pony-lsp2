use "../../upstream/tools/lib/ponylang/pony_syntax"

primitive CheckLegality
  """
  ponyc's `syntax`-pass legality rules that need nothing but the tree,
  ported with ponyc's own wordings: the entity and method permission
  tables from `pass/syntax.c` row for row, the Main checks, the reserved
  `_` names, the type-alias type requirement, the provides-type shape,
  object-literal legality, compile intrinsics and errors, semicolon
  placement, FFI legality, bare lambdas, ifdef flags, constraints,
  consume shapes, and casts.
  """
  fun apply(
    file: String val,
    source: String val,
    tree: SyntaxTree val)
    : Array[CheckDiagnostic] val
  =>
    recover val
      let out = Array[CheckDiagnostic]
      // Offsets and widths by element index, so structure walks below can
      // locate any element without recomputing.
      let at = Array[USize](tree.size())
      let width = Array[USize](tree.size())
      for (_, _, a, _, w) in tree.walk() do
        at.push(a)
        width.push(w.usize())
      end

      // Where constraints sit, as element ranges, so a rule about what
      // a constraint may hold can test whether an element is inside
      // one. Two sets, because ponyc's tuple rule applies only to
      // type-parameter constraints while its arrow rule also covers
      // iftype constraints. Type-argument ranges are collected too:
      // ponyc clears the constraint frame on entering type arguments,
      // so an arrow or tuple inside a constraint's type arguments is
      // legal, and the innermost enclosing marker is the one that
      // applies.
      let tp_constraints = _ConstraintRanges(tree where with_iftype = false)
      let constraints = _ConstraintRanges(tree where with_iftype = true)
      let typeargs = _TypeArgRanges(tree)
      // The walk queries these with strictly increasing element
      // indices, which is what lets each tracker advance a cursor
      // instead of rescanning every range per element.
      let in_constraint = _ConstraintTracker(constraints, typeargs)
      let in_tp_constraint = _ConstraintTracker(tp_constraints, typeargs)
      let gencap_constraint = _ConstraintTracker(constraints, typeargs)

      // The enclosing elements of the one being visited, maintained from
      // the walk's depths, so a rule that depends on where a construct
      // sits -- a body, an FFI declaration, a trait -- can read the chain
      // instead of re-walking.
      let stack = Array[(USize, SyntaxKind)]
      var default_method_scope: USize = 0
        """
        Below this element index, an FFI call sits inside a trait or
        interface. Zero when not inside one.
        """

      for (element, depth, a, kind, w) in tree.walk() do
        stack.truncate(depth)
        if kind is NdClassDef then
          _entity(file, source, tree, element, a, w.usize(), at, width,
            out)
          if _is_default_method_entity(tree, element) then
            default_method_scope = element + (try
              tree.subtree_size(element)?
            else
              0
            end)
          end
        elseif kind is NdObject then
          _object(file, source, tree, element, at, width, out)
        elseif kind is NdUseFFI then
          _ffi(file, tree, element, true, at, width, out)
        elseif kind is NdFFICall then
          _ffi(file, tree, element, false, at, width, out)
          if element < default_method_scope then
            _diag(file, element, at, width, out,
              "Can't call an FFI function in a default method or behavior")
          end
        elseif (kind is NdBareLambda) or (kind is NdBareLambdaType) then
          _bare_lambda(file, tree, element, at, width, out)
        elseif kind is NdIfDef then
          _ifdef_flags(file, source, tree, element, at, width, out)
        elseif kind is NdUse then
          _use_guard_flags(file, source, tree, element, at, width, out)
        elseif kind is NdSeq then
          _seq(file, source, tree, element, stack, at, width, out)
        elseif kind is TkEllipsis then
          _ellipsis(file, tree, element, stack, at, width, out)
        elseif kind is NdViewpoint then
          if in_constraint(element) then
            _diag(file, _anchor(tree, element), at, width, out,
              "arrow types can't be used as type constraints")
          end
        elseif kind is NdTupleType then
          if in_tp_constraint(element) then
            _diag(file, _anchor(tree, element), at, width, out,
              "tuple types can't be used as type constraints")
          end
        elseif kind is NdNominal then
          _gencap_outside_constraint(
            file, tree, element, gencap_constraint, at, width, out)
        elseif kind is NdConsume then
          _consume(file, tree, element, at, width, out)
        elseif kind is NdAsOp then
          _cast(file, tree, element, at, width, out)
        elseif kind is NdAnnotations then
          _annotations(file, source, tree, element, at, width, out)
        end
        stack.push((element, kind))
      end
      out
    end

  fun _is_default_method_entity(tree: SyntaxTree val, element: USize)
    : Bool
  =>
    try
      for child in tree.children(element)? do
        match tree.kind(child)?
        | TkTrait | TkInterface => return true
        | TkId => return false
        end
      end
    end
    false

  fun _ffi(
    file: String val,
    tree: SyntaxTree val,
    element: USize,
    is_declaration: Bool,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    try
      for child in tree.children(element)? do
        match tree.kind(child)?
        | NdTypeArgs =>
          var types: USize = 0
          for arg in tree.children(child)? do
            match tree.kind(arg)?
            | NdNominal | NdInfixType | NdGroupedType | NdTupleType
            | NdLambdaType | NdBareLambdaType | NdViewpoint
            | NdThisType => types = types + 1
            end
          end
          // A declaration must name exactly one return type; a call may
          // name none, but never more than one.
          if (types > 1) or (is_declaration and (types != 1)) then
            _diag(file, child, at, width, out,
              "FFI functions must specify a single return type")
          end
        | TkQuestion =>
          _diag(file, child, at, width, out,
            "Partial FFI is no longer supported. 'pony_error()' has been " +
              "removed, so an FFI " +
              (if is_declaration then "declaration" else "call" end) +
              " can no longer be partial. Remove the '?'.")
        | NdParams =>
          if is_declaration then
            for param in tree.children(child)? do
              if tree.kind(param)? is NdParam then
                for part in tree.children(param)? do
                  if tree.kind(part)? is NdDefaultArg then
                    _diag(file, _anchor(tree, part), at, width, out,
                      "FFIs parameters cannot have default values")
                  end
                end
              end
            end
          end
        end
      end
    end

  fun _ellipsis(
    file: String val,
    tree: SyntaxTree val,
    element: USize,
    stack: Array[(USize, SyntaxKind)] box,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    // ponyc's `syntax_ellipsis` tests the grandparent alone: the
    // ellipsis's parameter list must itself belong to an FFI
    // declaration, so an ellipsis in a lambda or method nested inside
    // an FFI call is still an error.
    (let params, let params_kind) =
      try stack(stack.size() - 1)? else return end
    if not (params_kind is NdParams) then
      return
    end
    let grandparent_kind =
      try stack(stack.size() - 2)?._2 else NdModule end
    if not (grandparent_kind is NdUseFFI) then
      _diag(file, element, at, width, out,
        "... may only appear in FFI declarations")
    end
    // Last parameter: no parameter node after this token.
    try
      var after = false
      for child in tree.children(params)? do
        if child == element then
          after = true
        elseif after and (tree.kind(child)? is NdParam) then
          _diag(file, element, at, width, out,
            "... must be the last parameter")
          break
        end
      end
    end

  fun _bare_lambda(
    file: String val,
    tree: SyntaxTree val,
    element: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    var after_body = false
    try
      for child in tree.children(element)? do
        match tree.kind(child)?
        | TkRbrace => after_body = true
        | NdTypeParams =>
          _diag(file, child, at, width, out,
            "a bare lambda cannot specify type parameters")
        | NdLambdaCaptures =>
          _diag(file, child, at, width, out,
            "a bare lambda cannot specify captures")
        | TkIso | TkTrn | TkRef | TkBox | TkTag =>
          if after_body then
            _diag(file, child, at, width, out,
              "a bare lambda can only have a 'val' capability")
          else
            _diag(file, child, at, width, out,
              "a bare lambda cannot specify a receiver capability")
          end
        | TkVal =>
          if not after_body then
            _diag(file, child, at, width, out,
              "a bare lambda cannot specify a receiver capability")
          end
        end
      end
    end

  fun _ifdef_flags(
    file: String val,
    source: String val,
    tree: SyntaxTree val,
    ifdef_el: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    """
    Run the flag rules over each condition of an `ifdef`.
    """
    try
      var in_condition = false
      for child in tree.children(ifdef_el)? do
        match tree.kind(child)?
        | TkIfdef | TkElseif => in_condition = true
        | TkThen => return
        else
          if not in_condition then continue end
          _condition_flags(file, source, tree, child, at, width, out)
        end
      end
    end

  fun _use_guard_flags(
    file: String val,
    source: String val,
    tree: SyntaxTree val,
    use_el: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    """
    The flag rules on a `use` guard: ponyc's syntax pass runs the ifdef
    condition check on it, so an unknown or reserved flag is an error
    whatever the scheme.
    """
    try
      var in_guard = false
      for child in tree.children(use_el)? do
        match tree.kind(child)?
        | TkIf => in_guard = true
        else
          if in_guard then
            _condition_flags(file, source, tree, child, at, width, out)
          end
        end
      end
    end

  fun _condition_flags(
    file: String val,
    source: String val,
    tree: SyntaxTree val,
    child: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    """
    The flag rules over one condition subtree: a string is a user build
    flag, which must not be a platform name or a reserved flag; a bare
    name is a platform flag, which must be in ponyc's table.
    """
    try
      let size = try tree.subtree_size(child)? else 1 end
      var i = child
      while i < (child + size) do
        match tree.kind(i)?
        | TkString =>
          let name = StringLiteralValue(_Text(source, at, width, i))
          if _Platforms.known(name.lower()) or
            _Platforms.illegal(name.lower())
          then
            _diag(file, i, at, width, out,
              "\"" + name + "\" is not a valid user build flag\n")
          end
        | NdRef =>
          for part in tree.children(i)? do
            if tree.kind(part)? is TkId then
              let name = _Text(source, at, width, part)
              if not _Platforms.known(name) then
                _diag(file, i, at, width, out,
                  "\"" + name + "\" is not a valid platform flag\n")
              end
            end
          end
        end
        i = i + 1
      end
    end

  fun _seq(
    file: String val,
    source: String val,
    tree: SyntaxTree val,
    seq: USize,
    stack: Array[(USize, SyntaxKind)] box,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    """
    Rules about a sequence's own children: semicolons separate expressions
    on the same line and nothing else, and the compile intrinsics and
    errors may only be a body, whole.
    """
    let parent_kind =
      try stack(stack.size() - 1)?._2 else NdModule end
    let grandparent_kind =
      try stack(stack.size() - 2)?._2 else NdModule end

    var prev_stmt: (USize | None) = None
    var semi_since_prev = false
    var newline_since_prev = false

    try
      for child in tree.children(seq)? do
        let kind = tree.kind(child)?
        match kind
        | TkWhitespace =>
          if _Text(source, at, width, child).contains("\n") then
            newline_since_prev = true
          end
        | TkLineComment => newline_since_prev = true
        | TkNestedComment => None
        | TkSemi =>
          semi_since_prev = true
          // A semicolon separates two expressions on one line. One that
          // follows a line break, reaches a line end, or reaches the
          // sequence's end separates nothing: ponyc's bad-semi flag.
          if newline_since_prev then
            _diag(file, child, at, width, out,
              "Unexpected semicolon, only use to separate expressions " +
                "on the same line")
            newline_since_prev = false
            continue
          end
          var j = child + 1
          var bad = j >= (seq + tree.subtree_size(seq)?)
          try
            while j < (seq + tree.subtree_size(seq)?) do
              match tree.kind(j)?
              | TkWhitespace =>
                if _Text(source, at, width, j).contains("\n") then
                  bad = true
                  break
                end
              | TkLineComment =>
                bad = true
                break
              else
                break
              end
              j = j + 1
            end
            if j >= (seq + tree.subtree_size(seq)?) then
              bad = true
            end
          end
          if bad then
            _diag(file, child, at, width, out,
              "Unexpected semicolon, only use to separate expressions " +
                "on the same line")
          end
        else
          // Every statement -- node or leaf, a docstring included --
          // follows the same separation rules; a docstring differs
          // only in `_sole_statement`.
          match prev_stmt
          | let _: USize =>
            if (not semi_since_prev) and (not newline_since_prev) then
              _diag(file, child, at, width, out,
                "Use a semi colon to separate expressions on the same " +
                  "line")
            end
          end
          prev_stmt = child
          semi_since_prev = false
          newline_since_prev = false

          if kind is NdJump then
            _jump(file, tree, child, seq, stack, parent_kind,
              grandparent_kind, at, width, out)
          end
        end
      end
    end

  fun _jump(
    file: String val,
    tree: SyntaxTree val,
    jump: USize,
    seq: USize,
    stack: Array[(USize, SyntaxKind)] box,
    parent_kind: SyntaxKind,
    grandparent_kind: SyntaxKind,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    var keyword: (SyntaxKind | None) = None
    var value: (USize | None) = None
    try
      for child in tree.children(jump)? do
        match tree.kind(child)?
        | TkCompileIntrinsic => keyword = TkCompileIntrinsic
        | TkCompileError => keyword = TkCompileError
        | TkReturn | TkBreak => keyword = TkReturn
        | TkContinue | TkError => keyword = TkContinue
        | NdSeq => value = child
        end
      end
    end

    // A jump swallows what follows it into its value sequence, so
    // ponyc's "Unreachable code" is a bound on that sequence: one
    // expression for `return` and `break`, none for `continue` and
    // `error`. Anything past the bound is unreachable. ponyc's second
    // clause walks the enclosing sequence chain: a parenthesised jump
    // gets its own inner sequence, so the bound never counts a
    // statement after the parentheses and only the walk reports it.
    match keyword
    | TkReturn | TkContinue =>
      let bound: USize = if keyword is TkReturn then 1 else 0 end
      var reported = false
      match value
      | let v: USize =>
        try
          var count: USize = 0
          for part in tree.children(v)? do
            match tree.kind(part)?
            | TkWhitespace | TkLineComment | TkNestedComment
            | TkSemi => None
            else
              count = count + 1
              if count > bound then
                _diag(file, part, at, width, out, "Unreachable code")
                reported = true
                break
              end
            end
          end
        end
      end
      if not reported then
        _climb_unreachable(file, tree, jump, seq, stack, at, width, out)
      end
      return
    end

    match keyword
    | TkCompileIntrinsic =>
      if not (parent_kind is NdMethod) then
        _diag(file, jump, at, width, out,
          "a compile intrinsic must be a method body")
      elseif (value isnt None) or
        (not _sole_statement(tree, seq, jump where allow_docstring = true))
      then
        _diag(file, jump, at, width, out,
          "a compile intrinsic must be the entire body")
      end
    | TkCompileError =>
      let in_ifdef =
        (parent_kind is NdIfDef) or
          (((parent_kind is NdThen) or (parent_kind is NdElse)) and
            (grandparent_kind is NdIfDef))
      if not in_ifdef then
        _diag(file, jump, at, width, out,
          "a compile error must be in an ifdef")
        return
      end
      let reason_ok =
        try
          match value
          | let v: USize =>
            var strings: USize = 0
            var others: USize = 0
            for part in tree.children(v)? do
              match tree.kind(part)?
              | TkString => strings = strings + 1
              | TkWhitespace | TkLineComment | TkNestedComment => None
              else
                others = others + 1
              end
            end
            (strings == 1) and (others == 0)
          | None => false
          end
        else
          false
        end
      if not reason_ok then
        _diag(file, jump, at, width, out,
          "a compile error must have a string literal reason for the error")
      elseif not
        _sole_statement(tree, seq, jump where allow_docstring = false)
      then
        _diag(file, jump, at, width, out,
          "a compile error must be the entire ifdef clause")
      end
    end

  fun _climb_unreachable(
    file: String val,
    tree: SyntaxTree val,
    jump: USize,
    seq: USize,
    stack: Array[(USize, SyntaxKind)] box,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    """
    ponyc's second unreachable-code clause: from the jump, walk the
    enclosing sequence chain outward and report the first statement
    that follows at any level, stepping through a parenthesised group,
    which ponyc's tree has no node for.
    """
    var current = jump
    var parent = seq
    var parent_kind: SyntaxKind = NdSeq
    var i = stack.size()
    try
      while true do
        if parent_kind is NdSeq then
          match _next_statement(tree, parent, current)?
          | let sibling: USize =>
            _diag(file, sibling, at, width, out, "Unreachable code")
            return
          end
        elseif not (parent_kind is NdGrouped) then
          return
        end
        current = parent
        if i == 0 then
          return
        end
        i = i - 1
        (parent, parent_kind) = stack(i)?
      end
    end

  fun _next_statement(tree: SyntaxTree val, parent: USize, current: USize)
    : (USize | None) ?
  =>
    var after = false
    for child in tree.children(parent)? do
      if child == current then
        after = true
      elseif after then
        match tree.kind(child)?
        | TkWhitespace | TkLineComment | TkNestedComment | TkSemi => None
        else
          return child
        end
      end
    end
    None

  fun _sole_statement(
    tree: SyntaxTree val,
    seq: USize,
    stmt: USize,
    allow_docstring: Bool)
    : Bool
  =>
    """
    Whether `stmt` is the only statement its sequence holds. A leading
    docstring is excused only where ponyc excuses one -- before a compile
    intrinsic, never before a compile error.
    """
    try
      var seen_docstring = false
      for child in tree.children(seq)? do
        match tree.kind(child)?
        | TkWhitespace | TkLineComment | TkNestedComment | TkSemi => None
        | TkString =>
          if (not allow_docstring) or seen_docstring or (child > stmt) then
            return false
          end
          seen_docstring = true
        else
          if child != stmt then
            return false
          end
        end
      end
      true
    else
      false
    end

  fun _entity(
    file: String val,
    source: String val,
    tree: SyntaxTree val,
    element: USize,
    a: USize,
    w: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    var found: (_EntityKind | None) = None
    var name: String val = ""
    var name_i: (USize | None) = None
    var c_api: (USize | None) = None
    var defcap: (USize | None) = None
    var typeparams: (USize | None) = None
    var provides: (USize | None) = None
    var members: (USize | None) = None

    try
      for child in tree.children(element)? do
        match tree.kind(child)?
        | TkActor => found = _Actor
        | TkClass => found = _Class
        | TkStruct => found = _Struct
        | TkPrimitive => found = _Primitive
        | TkTrait => found = _Trait
        | TkInterface => found = _Interface
        | TkType => found = _TypeAlias
        | TkAt => c_api = child
        | TkIso | TkTrn | TkRef | TkVal | TkBox | TkTag =>
          if name_i is None then defcap = child end
        | TkId =>
          if name_i is None then
            name_i = child
            name = _Text(source, at, width, child)
          end
        | NdTypeParams => typeparams = child
        | NdProvides => provides = child
        | NdMembers => members = child
        end
      end
    end

    // The grammar builds an entity node only on one of the seven
    // keywords, so the keyword child is always present.
    let ent =
      match found
      | let k: _EntityKind => k
      | None => _Unreachable(); _Actor
      end
    let desc = _EntityDesc(ent)

    if name == "Main" then
      match typeparams
      | let tp: USize =>
        _diag(file, tp, at, width, out,
          "the Main actor cannot have type parameters")
      end
      if _EntityPerm.main(ent) == 'N' then
        out.push(CheckDiagnostic(file, a, w, "Main must be an actor"))
      end
    end
    if name == "_" then
      match name_i
      | let id: USize =>
        _diag(file, id, at, width, out, desc + " name cannot be \"_\"")
      end
    end
    match defcap
    | let cap: USize if _EntityPerm.cap(ent) == 'N' =>
      _diag(file, cap, at, width, out,
        desc + " cannot specify default capability")
    end
    match c_api
    | let bare: USize =>
      if _EntityPerm.c_api(ent) == 'N' then
        _diag(file, bare, at, width, out, desc + " cannot specify C api")
      end
      match typeparams
      | let tp: USize =>
        _diag(file, tp, at, width, out,
          "generic actor cannot specify C api")
      end
    end
    if ent is _TypeAlias then
      if provides is None then
        match name_i
        | let id: USize =>
          _diag(file, id, at, width, out, "a type alias must specify a type")
        end
      end
    else
      match provides
      | let pr: USize => _provides(file, tree, pr, at, width, out)
      end
    end
    match members
    | let ms: USize =>
      _members(file, source, tree, ent, ms, at, width, out)
    end

  fun _members(
    file: String val,
    source: String val,
    tree: SyntaxTree val,
    ent: _EntityKind,
    members: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    try
      for member in tree.children(members)? do
        match tree.kind(member)?
        | NdField =>
          if _EntityPerm.field(ent) == 'N' then
            _diag(file, member, at, width, out,
              "Can't have fields in " + _EntityDesc(ent))
          end
          _id_is(file, source, tree, member, "field", at, width, out)
        | NdMethod =>
          _method(file, source, tree, ent, member, at, width, out)
        end
      end
    end

  fun _method(
    file: String val,
    source: String val,
    tree: SyntaxTree val,
    ent: _EntityKind,
    method: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    var found: (_MethodKind | None) = None
    var cap: (USize | None) = None
    var bare: (USize | None) = None
    var ret: (USize | None) = None
    var err: (USize | None) = None
    var body = false
    var body_el: (USize | None) = None
    var named = false
    // ponyc reports a forbidden return type at the type and a
    // forbidden body at the body, so both anchor at the node after
    // their marker token.
    var after_colon = false
    var after_arrow = false

    try
      for child in tree.children(method)? do
        match tree.kind(child)?
        | TkWhitespace | TkLineComment | TkNestedComment => None
        | TkFun => found = _Fun
        | TkBe => found = _Be
        | TkNew => found = _New
        | TkIso | TkTrn | TkRef | TkVal | TkBox | TkTag =>
          if not named then cap = child end
        | TkAt => if not named then bare = child end
        | TkId => named = true
        | TkColon =>
          ret = child
          after_colon = true
        | TkQuestion => err = child
        | TkDblarrow =>
          body = true
          after_arrow = true
        else
          if after_arrow then
            body_el = child
            after_arrow = false
          elseif after_colon then
            ret = child
            after_colon = false
          end
        end
      end
    end

    // The grammar builds a method node only on fun, be or new, so the
    // keyword child is always present.
    let mkind =
      match found
      | let k: _MethodKind => k
      | None => _Unreachable(); _Fun
      end
    let desc = _MethodDesc(mkind, ent)
    match _MethodPerm(mkind, ent)
    | None =>
      _diag(file, method, at, width, out, desc + "s are not allowed")
      return
    | let perms: String val =>
      _element(file, perms, 0, cap, method, "receiver capability", desc,
        at, width, out)
      _element(file, perms, 1, bare, method, "bareness", desc,
        at, width, out)
      _element(file, perms, 2, ret, method, "return type", desc,
        at, width, out)
      _element(file, perms, 3, err, method, "?", desc, at, width, out)
      let body_at: (USize | None) =
        if body then
          match body_el
          | let el: USize => el
          | None => method
          end
        else
          None
        end
      _element(file, perms, 4, body_at, method, "body", desc,
        at, width, out)
    end
    _id_is(file, source, tree, method, "method", at, width, out)

  fun _element(
    file: String val,
    perms: String val,
    index: USize,
    actual: (USize | None),
    report_at: USize,
    context: String val,
    desc: String val,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    let permission = try perms(index)? else _Unreachable(); 'X' end
    if (permission == 'N') and (actual isnt None) then
      match actual
      | let el: USize =>
        _diag(file, el, at, width, out,
          desc + " cannot specify " + context)
      end
    elseif (permission == 'Y') and (actual is None) then
      _diag(file, report_at, at, width, out,
        desc + " must specify " + context)
    end

  fun _provides(
    file: String val,
    tree: SyntaxTree val,
    provides: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    try
      for child in tree.children(provides)? do
        match tree.kind(child)?
        | TkIs | NdError
        | TkWhitespace | TkLineComment | TkNestedComment => None
        else
          _provides_type(file, tree, child, at, width, out)
        end
      end
    end

  fun _provides_type(
    file: String val,
    tree: SyntaxTree val,
    element: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    """
    ponyc's `check_provides_type`: a provides type is a nominal without a
    capability, an intersection of such, or parentheses around one. A `|`
    in an infix type, or any other type shape, is invalid there.
    """
    try
      match tree.kind(element)?
      | NdNominal =>
        for child in tree.children(element)? do
          match tree.kind(child)?
          | TkIso | TkTrn | TkRef | TkVal | TkBox | TkTag
          | TkCapRead | TkCapSend | TkCapShare | TkCapAlias | TkCapAny =>
            _diag(file, child, at, width, out,
              "can't specify a capability in a provides type")
          | TkEphemeral | TkAliased =>
            _diag(file, child, at, width, out,
              "can't specify ephemeral in a provides type")
          end
        end
      | NdInfixType =>
        for child in tree.children(element)? do
          match tree.kind(child)?
          | TkPipe =>
            _diag(file, child, at, width, out, _invalid_provides())
            return
          | NdNominal | NdGroupedType | NdInfixType =>
            _provides_type(file, tree, child, at, width, out)
          | TkIsecttype => None
          | TkWhitespace | TkLineComment | TkNestedComment =>
            // The tree is lossless, so trivia are children here too.
            None
          else
            _diag(file, element, at, width, out, _invalid_provides())
            return
          end
        end
      | NdGroupedType =>
        for child in tree.children(element)? do
          match tree.kind(child)?
          | TkLparen | TkLparenNew | TkRparen | NdError
          | TkWhitespace | TkLineComment | TkNestedComment => None
          else
            _provides_type(file, tree, child, at, width, out)
          end
        end
      else
        _diag(file, _anchor(tree, element), at, width, out,
          _invalid_provides())
      end
    end

  fun _anchor(tree: SyntaxTree val, element: USize): USize =>
    """
    The element a diagnostic about a constructed node is reported
    against. ponyc's AST positions such a node at the token that formed
    it — a tuple at its comma, a viewpoint at its arrow, a dotted
    access at its dot, a default argument at its value — where this
    tree's nodes start at their first child.
    """
    try
      let want =
        match tree.kind(element)?
        | NdTupleType => TkComma
        | NdViewpoint => TkArrow
        | NdDot => TkDot
        | NdDefaultArg =>
          for child in tree.children(element)? do
            match tree.kind(child)?
            | TkAssign | TkWhitespace | TkLineComment
            | TkNestedComment => None
            else
              return child
            end
          end
          return element
        else
          return element
        end
      for child in tree.children(element)? do
        if tree.kind(child)? is want then
          return child
        end
      end
    end
    element

  fun _invalid_provides(): String val =>
    "invalid provides type. Can only be interfaces, traits and intersects " +
      "of those."

  fun _object(
    file: String val,
    source: String val,
    tree: SyntaxTree val,
    obj: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    """
    ponyc's `syntax_object`: an object literal's members go through the
    actor permission tables, its provides list through the provides
    rules, and its fields must carry an initialiser.
    """
    try
      for child in tree.children(obj)? do
        match tree.kind(child)?
        | NdProvides => _provides(file, tree, child, at, width, out)
        | NdMembers =>
          _members(file, source, tree, _Actor, child, at, width, out)
          for member in tree.children(child)? do
            if tree.kind(member)? is NdField then
              var initialised = false
              for part in tree.children(member)? do
                if tree.kind(part)? is TkAssign then
                  initialised = true
                end
              end
              if not initialised then
                _diag(file, member, at, width, out,
                  "object literal fields must be initialized")
              end
            end
          end
        end
      end
    end

  fun _id_is(
    file: String val,
    source: String val,
    tree: SyntaxTree val,
    parent: USize,
    what: String val,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    try
      for child in tree.children(parent)? do
        if tree.kind(child)? is TkId then
          if _Text(source, at, width, child) == "_" then
            _diag(file, child, at, width, out,
              what + " name cannot be \"_\"")
          end
          return
        end
      end
    end

  fun _gencap_outside_constraint(
    file: String val,
    tree: SyntaxTree val,
    nominal: USize,
    in_constraint: _ConstraintTracker,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    if in_constraint(nominal) then
      return
    end
    try
      for child in tree.children(nominal)? do
        match tree.kind(child)?
        | TkCapRead | TkCapSend | TkCapShare | TkCapAlias | TkCapAny =>
          _diag(file, child, at, width, out,
            "a capability set can only appear in a type constraint")
        end
      end
    end

  fun _consume(
    file: String val,
    tree: SyntaxTree val,
    consume_el: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    try
      for child in tree.children(consume_el)? do
        match tree.kind(child)?
        | TkConsume | TkWhitespace | TkLineComment | TkNestedComment
        | TkIso | TkTrn | TkRef | TkVal | TkBox | TkTag => None
        | NdRef | NdThis => return
        | NdDot =>
          // A dotted target is fine unless what is left of the dot is a
          // call or a parenthesised expression -- consuming a field of a
          // temporary consumes nothing.
          for part in tree.children(child)? do
            match tree.kind(part)?
            | TkWhitespace | TkLineComment | TkNestedComment => None
            | NdCall =>
              _diag(file, _anchor(tree, child), at, width, out,
                "Consume expressions must specify an identifier or field")
              return
            | NdGrouped =>
              // ponyc rejects a parenthesised expression left of the dot
              // but accepts a tuple, and this tree parses a tuple as a
              // group wrapping one, so the rule applies to the group's
              // content.
              for inner in tree.children(part)? do
                match tree.kind(inner)?
                | TkWhitespace | TkLineComment | TkNestedComment
                | TkLparen | TkLparenNew => None
                | NdTuple => return
                else
                  _diag(file, _anchor(tree, child), at, width, out,
                    "Consume expressions must specify an identifier or " +
                      "field")
                  return
                end
              end
              return
            else
              return
            end
          end
          return
        else
          _diag(file, child, at, width, out,
            "Consume expressions must specify an identifier or field")
          return
        end
      end
    end

  fun _cast(
    file: String val,
    tree: SyntaxTree val,
    as_el: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    try
      for child in tree.children(as_el)? do
        match tree.kind(child)?
        | TkWhitespace | TkLineComment | TkNestedComment => None
        | TkInt | TkFloat =>
          let a = try at(child)? else 0 end
          let w = try width(child)? else 0 end
          out.push(
            CheckDiagnostic(file, a, w,
              "Cannot cast uninferred numeric literal",
              CheckDiagnostic(file, a, w,
                "To give a numeric literal a specific type, use the " +
                  "constructor of that numeric type")))
          return
        else
          return
        end
      end
    end

  fun _annotations(
    file: String val,
    source: String val,
    tree: SyntaxTree val,
    anns: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref)
  =>
    try
      for child in tree.children(anns)? do
        if tree.kind(child)? is TkId then
          if _Text(source, at, width, child)
            .compare_sub("ponyint", 7) is Equal
          then
            _diag(file, child, at, width, out,
              "annotations starting with 'ponyint' are reserved for " +
                "internal use")
          end
        end
      end
    end

  fun _diag(
    file: String val,
    element: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiagnostic] ref,
    message: String val)
  =>
    let a = try at(element)? else 0 end
    let w = try width(element)? else 0 end
    out.push(CheckDiagnostic(file, a, w, message))

primitive _Actor
primitive _Class
primitive _Struct
primitive _Primitive
primitive _Trait
primitive _Interface
primitive _TypeAlias

type _EntityKind is
  (_Actor | _Class | _Struct | _Primitive | _Trait | _Interface |
    _TypeAlias)
  """
  The entity axis of ponyc's permission tables, one primitive per
  keyword, so a match over the rows is exhaustive and a missing row is
  a compile error rather than a fail-open default.
  """

primitive _Fun
primitive _Be
primitive _New

type _MethodKind is (_Fun | _Be | _New)
  """
  The method axis of the same tables.
  """

primitive _EntityDesc
  fun apply(ent: _EntityKind): String val =>
    match ent
    | _Actor => "actor"
    | _Class => "class"
    | _Struct => "struct"
    | _Primitive => "primitive"
    | _Trait => "trait"
    | _Interface => "interface"
    | _TypeAlias => "type alias"
    end

primitive _EntityPerm
  """
  ponyc's `_entity_def` table: whether each entity kind may be Main, have
  fields, take a default capability, or take a C api annotation.
  """
  fun main(ent: _EntityKind): U8 => _perm(ent, 0)
  fun field(ent: _EntityKind): U8 => _perm(ent, 1)
  fun cap(ent: _EntityKind): U8 => _perm(ent, 2)
  fun c_api(ent: _EntityKind): U8 => _perm(ent, 3)

  fun _perm(ent: _EntityKind, element: USize): U8 =>
    let row =
      match ent
      | _Actor => "XXNX"
      | _Class => "NXXN"
      | _Struct => "NXXN"
      | _Primitive => "NNNN"
      | _Trait => "NNXN"
      | _Interface => "NNXN"
      | _TypeAlias => "NNNN"
      end
    try row(element)? else _Unreachable(); 'X' end

primitive _MethodDesc
  fun apply(mkind: _MethodKind, ent: _EntityKind): String val =>
    _EntityDesc(ent) + " " +
      (match mkind
      | _Fun => "function"
      | _Be => "behaviour"
      | _New => "constructor"
      end)

primitive _MethodPerm
  """
  ponyc's `_method_def` table, by method kind and entity kind: the five
  elements are receiver capability, bareness, return type, `?`, and body;
  `None` is a row ponyc disallows outright.
  """
  fun apply(mkind: _MethodKind, ent: _EntityKind): (String val | None) =>
    match mkind
    | _Fun =>
      match ent
      | _Trait | _Interface => "XXXXX" // body optional
      | _TypeAlias => None
      | _Actor | _Class | _Struct | _Primitive => "XXXXY"
      end
    | _Be =>
      match ent
      | _Actor => "NNNNY"
      | _Trait | _Interface => "NNNNX"
      | _Class | _Struct | _Primitive | _TypeAlias => None
      end
    | _New =>
      match ent
      | _Actor => "NNNNY"
      | _Class | _Struct => "XNNXY"
      | _Primitive => "NNNXY"
      | _Trait | _Interface => "XNNXN"
      | _TypeAlias => None
      end
    end


class _ConstraintTracker
  """
  Whether an element sits in a constraint, matching ponyc's frame:
  entering type arguments clears the constraint, so an element is in a
  constraint only when the innermost enclosing constraint range is
  nearer than every enclosing type-argument range.

  The range tables arrive ordered by start element, and queries arrive
  in element order, so one cursor per table replaces a scan of every
  range per query.
  """
  let _constraints: Array[(USize, USize)] box
  let _typeargs: Array[(USize, USize)] box
  var _ci: USize = 0
  var _ti: USize = 0
  embed _copen: Array[(USize, USize)] = _copen.create()
  embed _topen: Array[(USize, USize)] = _topen.create()

  new create(
    constraints: Array[(USize, USize)] box,
    typeargs: Array[(USize, USize)] box)
  =>
    _constraints = constraints
    _typeargs = typeargs

  fun ref apply(element: USize): Bool =>
    _advance(element)
    let best =
      try
        let range = _copen(_copen.size() - 1)?
        range._2 - range._1
      else
        return false
      end
    try
      let range = _topen(_topen.size() - 1)?
      if (range._2 - range._1) < best then
        return false
      end
    end
    true

  fun ref _advance(element: USize) =>
    while
      try _copen(_copen.size() - 1)?._2 <= element else false end
    do
      try _copen.pop()? end
    end
    while
      try _constraints(_ci)?._1 <= element else false end
    do
      try
        let range = _constraints(_ci)?
        if range._2 > element then
          _copen.push(range)
        end
      end
      _ci = _ci + 1
    end
    while
      try _topen(_topen.size() - 1)?._2 <= element else false end
    do
      try _topen.pop()? end
    end
    while
      try _typeargs(_ti)?._1 <= element else false end
    do
      try
        let range = _typeargs(_ti)?
        if range._2 > element then
          _topen.push(range)
        end
      end
      _ti = _ti + 1
    end

primitive _TypeArgRanges
  """
  The element range of every type-argument list, ordered by start
  element. A tree that would produce them out of order crashes.
  """
  fun apply(tree: SyntaxTree val): Array[(USize, USize)] val =>
    recover val
      let out = Array[(USize, USize)]
      var last: USize = 0
      for (element, _, _, kind, _) in tree.walk() do
        if kind is NdTypeArgs then
          try
            if element < last then
              _Unreachable()
            end
            last = element
            out.push((element, element + tree.subtree_size(element)?))
          end
        end
      end
      out
    end

primitive _ConstraintRanges
  """
  The element ranges of every type-parameter constraint and every iftype
  constraint: for a type parameter, the type after its colon; for an
  iftype, the type after `<:`. Ordered by start element; a tree that
  would produce them out of order crashes.
  """
  fun apply(tree: SyntaxTree val, with_iftype: Bool)
    : Array[(USize, USize)] val
  =>
    recover val
      let out = Array[(USize, USize)]
      var last: USize = 0
      for (element, _, _, kind, _) in tree.walk() do
        if (kind is NdTypeParam) or
          (with_iftype and (kind is NdIfType))
        then
          try
            var in_constraint = false
            for child in tree.children(element)? do
              match tree.kind(child)?
              | TkColon | TkSubtype => in_constraint = true
              | NdDefaultArg | TkAssign | TkThen => in_constraint = false
              else
                if in_constraint and (not tree.is_leaf(child)?) then
                  if child < last then
                    _Unreachable()
                  end
                  last = child
                  out.push((child, child + tree.subtree_size(child)?))
                end
              end
            end
          end
        end
      end
      out
    end

primitive _Platforms
  """
  The platform flags ponyc's `os_is_target` tests, and the reserved
  user flags, from `platformfuns.h` and `syntax.c`.
  """
  fun known(name: String val): Bool =>
    match name
    | "bsd" | "freebsd" | "dragonfly" | "openbsd" | "linux" | "osx"
    | "windows" | "posix" | "x86" | "arm" | "lp64" | "llp64" | "ilp32"
    | "native128" | "debug" | "bigendian" | "littleendian"
    | "runtimestats" | "runtimestatsmessages" => true
    else
      false
    end

  fun illegal(name: String val): Bool =>
    match name
    | "ndebug" | "unknown_os" | "unknown_size" => true
    else
      false
    end

primitive _Text
  fun apply(
    source: String val,
    at: Array[USize] box,
    width: Array[USize] box,
    element: USize)
    : String val
  =>
    try
      let from = at(element)?
      source.substring(from.isize(), (from + width(element)?).isize())
    else
      ""
    end
