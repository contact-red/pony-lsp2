use "../../upstream/tools/lib/ponylang/pony_syntax"

primitive CheckLegality
  """
  ponyc's `syntax`-pass legality rules that need nothing but the tree:
  the entity and method permission tables from `pass/syntax.c`, ported row
  for row with ponyc's own wordings, plus the Main checks, the reserved
  `_` names, the type-alias type requirement, the provides-type shape, and
  object-literal field initialisation.

  The body-level rules from the same pass — compile intrinsics and
  errors, semicolon placement, FFI legality, bare lambdas, ifdef flags,
  constraints, consume shapes, casts — live here too, each verified
  against its corpus case.
  """
  fun apply(
    file: String val,
    source: String val,
    tree: SyntaxTree val)
    : Array[CheckDiag] val
  =>
    recover val
      let out = Array[CheckDiag]
      // Offsets and widths by element index, so structure walks below can
      // locate any element without recomputing.
      let at = Array[USize](tree.size())
      let width = Array[USize](tree.size())
      for (_, _, a, _, w) in tree.walk() do
        at.push(a)
        width.push(w.usize())
      end

      // Where constraints sit, as element ranges, so the rules about
      // what a constraint may hold can ask "is this element inside one"
      // with a scan. Two sets, because ponyc's tuple rule applies only to
      // type-parameter constraints while its arrow rule also covers
      // iftype constraints. Type-argument ranges are collected too:
      // ponyc clears the constraint frame on entering type arguments, so
      // an arrow or tuple inside a constraint's type arguments is legal,
      // and what decides is the innermost enclosing marker.
      let tp_constraints = _ConstraintRanges(tree, false)
      let constraints = _ConstraintRanges(tree, true)
      let typeargs = _TypeArgRanges(tree)

      // The enclosing elements of the one being visited, maintained from
      // the walk's depths, so a rule that depends on where a construct
      // sits -- a body, an FFI declaration, a trait -- can read the chain
      // instead of re-walking.
      let stack = Array[(USize, SyntaxKind)]
      var default_method_scope: USize = 0
        """
        Past this element index, an FFI call sits inside a trait or
        interface. Zero when not inside one.
        """

      for (element, depth, a, kind, w) in tree.walk() do
        stack.truncate(depth)
        if kind is NdClassDef then
          _entity(file, tree, element, a, w.usize(), at, width, out)
          if _is_default_method_entity(tree, element) then
            default_method_scope = element + (try
              tree.subtree_size(element)?
            else
              0
            end)
          end
        elseif kind is NdObject then
          _object_fields(file, tree, element, at, width, out)
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
          _ifdef_flags(file, tree, element, at, width, out)
        elseif kind is NdSeq then
          _seq(file, source, tree, element, stack, at, width, out)
        elseif kind is TkEllipsis then
          _ellipsis(file, tree, element, stack, at, width, out)
        elseif kind is NdViewpoint then
          if _InConstraint(constraints, typeargs, element) then
            _diag(file, element, at, width, out,
              "arrow types can't be used as type constraints")
          end
        elseif kind is NdTupleType then
          if _InConstraint(tp_constraints, typeargs, element) then
            _diag(file, element, at, width, out,
              "tuple types can't be used as type constraints")
          end
        elseif kind is NdNominal then
          _gencap_outside_constraint(
            file, tree, element, constraints, typeargs, at, width, out)
        elseif kind is NdConsume then
          _consume(file, tree, element, at, width, out)
        elseif kind is NdAsOp then
          _cast(file, tree, element, at, width, out)
        elseif kind is NdAnnotations then
          _annotations(file, tree, element, at, width, out)
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
    out: Array[CheckDiag] ref)
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
                    _diag(file, part, at, width, out,
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
    out: Array[CheckDiag] ref)
  =>
    var in_params: (USize | None) = None
    var in_ffi = false
    try
      var i = stack.size()
      while i > 0 do
        i = i - 1
        (let el, let kind) = stack(i)?
        if kind is NdParams then
          in_params = el
        elseif kind is NdUseFFI then
          in_ffi = true
        elseif kind is NdFFICall then
          in_ffi = true
        end
      end
    end
    match in_params
    | None => return
    | let params: USize =>
      if not in_ffi then
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
    end

  fun _bare_lambda(
    file: String val,
    tree: SyntaxTree val,
    element: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
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
    tree: SyntaxTree val,
    ifdef_el: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    """
    Flags in an `ifdef` condition: a string is a user build flag, which
    must not be a platform name or a reserved flag; a bare name is a
    platform flag, which must be one ponyc knows.
    """
    try
      var in_condition = false
      for child in tree.children(ifdef_el)? do
        match tree.kind(child)?
        | TkIfdef | TkElseif => in_condition = true
        | TkThen => return
        else
          if not in_condition then continue end
          let size = try tree.subtree_size(child)? else 1 end
          var i = child
          while i < (child + size) do
            match tree.kind(i)?
            | TkString =>
              let name = _Unquote(recover val tree.text(i)? end)
              if _Platforms.known(name.lower()) or
                _Platforms.illegal(name.lower())
              then
                _diag(file, i, at, width, out,
                  "\"" + name + "\" is not a valid user build flag")
              end
            | NdRef =>
              for part in tree.children(i)? do
                if tree.kind(part)? is TkId then
                  let name = recover val tree.text(part)? end
                  if not _Platforms.known(name) then
                    _diag(file, i, at, width, out,
                      "\"" + name + "\" is not a valid platform flag")
                  end
                end
              end
            end
            i = i + 1
          end
        end
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
    out: Array[CheckDiag] ref)
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
          if (recover val tree.text(child)? end).contains("\n") then
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
                if (recover val tree.text(j)? end).contains("\n") then
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
          if not tree.is_leaf(child)? then
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
              _jump(file, tree, child, seq, parent_kind, grandparent_kind,
                at, width, out)
            end
          else
            // A leaf statement -- a literal, a docstring string, a bare
            // reference -- follows the same separation rules as a node.
            // The docstring's only specialness is _sole_statement's.
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
          end
        end
      end
    end

  fun _jump(
    file: String val,
    tree: SyntaxTree val,
    jump: USize,
    seq: USize,
    parent_kind: SyntaxKind,
    grandparent_kind: SyntaxKind,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
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
    // `error`. Anything past the bound is unreachable.
    match keyword
    | TkReturn | TkContinue =>
      let bound: USize = if keyword is TkReturn then 1 else 0 end
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
                break
              end
            end
          end
        end
      end
      return
    end

    match keyword
    | TkCompileIntrinsic =>
      if not (parent_kind is NdMethod) then
        _diag(file, jump, at, width, out,
          "a compile intrinsic must be a method body")
      elseif (value isnt None) or (not _sole_statement(tree, seq, jump)) then
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
      elseif not _sole_statement(tree, seq, jump) then
        _diag(file, jump, at, width, out,
          "a compile error must be the entire ifdef clause")
      end
    end

  fun _sole_statement(tree: SyntaxTree val, seq: USize, stmt: USize)
    : Bool
  =>
    """
    Whether `stmt` is the only statement its sequence holds, a leading
    docstring aside.
    """
    try
      var seen_docstring = false
      for child in tree.children(seq)? do
        match tree.kind(child)?
        | TkWhitespace | TkLineComment | TkNestedComment | TkSemi => None
        | TkString =>
          if seen_docstring or (child > stmt) then
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
    tree: SyntaxTree val,
    element: USize,
    a: USize,
    w: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    var ent: USize = 0
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
        | TkActor => ent = 0
        | TkClass => ent = 1
        | TkStruct => ent = 2
        | TkPrimitive => ent = 3
        | TkTrait => ent = 4
        | TkInterface => ent = 5
        | TkType => ent = 6
        | TkAt => c_api = child
        | TkIso | TkTrn | TkRef | TkVal | TkBox | TkTag =>
          if name_i is None then defcap = child end
        | TkId =>
          if name_i is None then
            name_i = child
            name = recover val tree.text(child)? end
          end
        | NdTypeParams => typeparams = child
        | NdProvides => provides = child
        | NdMembers => members = child
        end
      end
    end

    let desc = _EntityDesc(ent)

    if name == "Main" then
      match typeparams
      | let tp: USize =>
        _diag(file, tp, at, width, out,
          "the Main actor cannot have type parameters")
      end
      if _EntityPerm.main(ent) == 'N' then
        out.push(CheckDiag(file, a, w, "Main must be an actor"))
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
      elseif typeparams isnt None then
        match typeparams
        | let tp: USize =>
          _diag(file, tp, at, width, out,
            "generic actor cannot specify C api")
        end
      end
    end
    if ent == 6 then
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
    | let ms: USize => _members(file, tree, ent, ms, at, width, out)
    end

  fun _members(
    file: String val,
    tree: SyntaxTree val,
    ent: USize,
    members: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    try
      for member in tree.children(members)? do
        match tree.kind(member)?
        | NdField =>
          if _EntityPerm.field(ent) == 'N' then
            _diag(file, member, at, width, out,
              "Can't have fields in " + _EntityDesc(ent))
          end
          _id_is(file, tree, member, "field", at, width, out)
        | NdMethod =>
          _method(file, tree, ent, member, at, width, out)
        end
      end
    end

  fun _method(
    file: String val,
    tree: SyntaxTree val,
    ent: USize,
    method: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    var mkind: USize = 0
    var cap: (USize | None) = None
    var bare: (USize | None) = None
    var ret: (USize | None) = None
    var err: (USize | None) = None
    var body = false
    var named = false

    try
      for child in tree.children(method)? do
        match tree.kind(child)?
        | TkFun => mkind = 0
        | TkBe => mkind = 1
        | TkNew => mkind = 2
        | TkIso | TkTrn | TkRef | TkVal | TkBox | TkTag =>
          if not named then cap = child end
        | TkAt => if not named then bare = child end
        | TkId => named = true
        | TkColon => ret = child
        | TkQuestion => err = child
        | TkDblarrow => body = true
        end
      end
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
      let body_el: (USize | None) = if body then method else None end
      _element(file, perms, 4, body_el, method, "body", desc,
        at, width, out)
    end
    _id_is(file, tree, method, "method", at, width, out)

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
    out: Array[CheckDiag] ref)
  =>
    let permission = try perms(index)? else 'X' end
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
    out: Array[CheckDiag] ref)
  =>
    try
      for child in tree.children(provides)? do
        match tree.kind(child)?
        | NdNominal | NdInfixType | NdGroupedType =>
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
    out: Array[CheckDiag] ref)
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
            _diag(file, element, at, width, out, _invalid_provides())
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
          | NdNominal | NdInfixType | NdGroupedType =>
            _provides_type(file, tree, child, at, width, out)
          end
        end
      else
        _diag(file, element, at, width, out, _invalid_provides())
      end
    end

  fun _invalid_provides(): String val =>
    "invalid provides type. Can only be interfaces, traits and intersects " +
      "of those."

  fun _object_fields(
    file: String val,
    tree: SyntaxTree val,
    obj: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    try
      for child in tree.children(obj)? do
        if tree.kind(child)? is NdMembers then
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
    tree: SyntaxTree val,
    parent: USize,
    what: String val,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    try
      for child in tree.children(parent)? do
        if tree.kind(child)? is TkId then
          if (recover val tree.text(child)? end) == "_" then
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
    constraints: Array[(USize, USize)] box,
    typeargs: Array[(USize, USize)] box,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    if _InConstraint(constraints, typeargs, nominal) then
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
    out: Array[CheckDiag] ref)
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
            | NdCall | NdGrouped =>
              _diag(file, child, at, width, out,
                "Consume expressions must specify an identifier or field")
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
    out: Array[CheckDiag] ref)
  =>
    try
      for child in tree.children(as_el)? do
        match tree.kind(child)?
        | TkWhitespace | TkLineComment | TkNestedComment => None
        | TkInt | TkFloat =>
          _diag(file, child, at, width, out,
            "Cannot cast uninferred numeric literal\n" +
              "To give a numeric literal a specific type, use the " +
              "constructor of that numeric type")
          return
        else
          return
        end
      end
    end

  fun _annotations(
    file: String val,
    tree: SyntaxTree val,
    anns: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    try
      for child in tree.children(anns)? do
        if tree.kind(child)? is TkId then
          if (recover val tree.text(child)? end)
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
    out: Array[CheckDiag] ref,
    message: String val)
  =>
    let a = try at(element)? else 0 end
    let w = try width(element)? else 0 end
    out.push(CheckDiag(file, a, w, message))

primitive _EntityDesc
  fun apply(ent: USize): String val =>
    match ent
    | 0 => "actor"
    | 1 => "class"
    | 2 => "struct"
    | 3 => "primitive"
    | 4 => "trait"
    | 5 => "interface"
    else
      "type alias"
    end

primitive _EntityPerm
  """
  ponyc's `_entity_def` table: whether each entity kind may be Main, have
  fields, take a default capability, or take a C api annotation.
  """
  fun main(ent: USize): U8 => _perm(ent, 0)
  fun field(ent: USize): U8 => _perm(ent, 1)
  fun cap(ent: USize): U8 => _perm(ent, 2)
  fun c_api(ent: USize): U8 => _perm(ent, 3)

  fun _perm(ent: USize, element: USize): U8 =>
    let row =
      match ent
      | 0 => "XXNX" // actor
      | 1 => "NXXN" // class
      | 2 => "NXXN" // struct
      | 3 => "NNNN" // primitive
      | 4 => "NNXN" // trait
      | 5 => "NNXN" // interface
      else
        "NNNN"      // type alias
      end
    try row(element)? else 'X' end

primitive _MethodDesc
  fun apply(mkind: USize, ent: USize): String val =>
    _EntityDesc(ent) + " " +
      (match mkind
      | 0 => "function"
      | 1 => "behaviour"
      else
        "constructor"
      end)

primitive _MethodPerm
  """
  ponyc's `_method_def` table, by method kind and entity kind: the five
  elements are receiver capability, bareness, return type, `?`, and body;
  `None` is a row ponyc disallows outright.
  """
  fun apply(mkind: USize, ent: USize): (String val | None) =>
    match mkind
    | 0 => // function
      match ent
      | 4 | 5 => "XXXXX" // trait, interface: body optional
      | 6 => None        // type alias
      else
        "XXXXY"
      end
    | 1 => // behaviour
      match ent
      | 0 => "NNNNY"     // actor
      | 4 | 5 => "NNNNX" // trait, interface
      else
        None
      end
    else // constructor
      match ent
      | 0 => "NNNNY"     // actor
      | 1 | 2 => "XNNXY" // class, struct
      | 3 => "NNNXY"     // primitive
      | 4 | 5 => "XNNXN" // trait, interface
      else
        None
      end
    end


primitive _InConstraint
  """
  Whether an element sits in a constraint, the way ponyc's frame does:
  the innermost enclosing marker decides, and entering type arguments
  clears the constraint, so only a constraint range that is nearer than
  every enclosing type-argument range counts.
  """
  fun apply(
    constraints: Array[(USize, USize)] box,
    typeargs: Array[(USize, USize)] box,
    element: USize)
    : Bool
  =>
    var best_constraint: USize = USize.max_value()
    for (from, to) in constraints.values() do
      if (element >= from) and (element < to) then
        if (to - from) < best_constraint then
          best_constraint = to - from
        end
      end
    end
    if best_constraint == USize.max_value() then
      return false
    end
    for (from, to) in typeargs.values() do
      if (element >= from) and (element < to) then
        if (to - from) < best_constraint then
          return false
        end
      end
    end
    true

primitive _TypeArgRanges
  fun apply(tree: SyntaxTree val): Array[(USize, USize)] val =>
    recover val
      let out = Array[(USize, USize)]
      for (element, _, _, kind, _) in tree.walk() do
        if kind is NdTypeArgs then
          try
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
  iftype, the type after `<:`.
  """
  fun apply(tree: SyntaxTree val, with_iftype: Bool)
    : Array[(USize, USize)] val
  =>
    recover val
      let out = Array[(USize, USize)]
      for (element, _, _, kind, _) in tree.walk() do
        if (kind is NdTypeParam) or
          (with_iftype and (kind is NdIfType))
        then
          try
            var in_constraint = false
            for child in tree.children(element)? do
              match tree.kind(child)?
              | TkColon | TkSubtype => in_constraint = true
              | NdDefaultArg | TkThen => in_constraint = false
              else
                if in_constraint and (not tree.is_leaf(child)?) then
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
  The platform flags ponyc's `os_is_target` answers for, and the reserved
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
