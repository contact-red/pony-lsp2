use "../../upstream/tools/lib/ponylang/pony_syntax"

class _Diags
  """
  One file's legality context: where diagnostics go, and how to locate
  and read an element — the file, its tree, and the per-element byte
  offsets the pass builds up front, because `SyntaxTree.offset` is
  linear in the element index.
  """
  let file: String val
  let tree: SyntaxTree val
  let at: Array[USize] box
  let out: Array[CheckDiagnostic] ref

  new create(
    file': String val,
    tree': SyntaxTree val,
    at': Array[USize] box,
    out': Array[CheckDiagnostic] ref)
  =>
    file = file'
    tree = tree'
    at = at'
    out = out'

  fun offset(element: USize): USize =>
    try at(element)? else _Unreachable(); 0 end

  fun ref report(element: USize, message: String val) =>
    out.push(CheckDiagnostic(file, offset(element), message))

  fun ref report_with_info(
    element: USize,
    message: String val,
    info: String val,
    info_element: (USize | None) = None)
  =>
    let info_at =
      match info_element
      | let e: USize => offset(e)
      | None => offset(element)
      end
    out.push(
      CheckDiagnostic(file, offset(element), message,
        CheckDiagnostic(file, info_at, info)))

  fun text(element: USize): String val =>
    let from = offset(element)
    let w = try tree.width(element)? else _Unreachable(); 0 end
    tree.source.substring(from.isize(), (from + w).isize())

primitive CheckLegality
  """
  ponyc's `syntax` pass, ported with ponyc's own wordings: the entity
  and method permission tables from `pass/syntax.c` row for row, the
  name rules from `ast/id.c`, the Main checks, the type-alias type
  requirement, the provides-type shape, object-literal legality,
  viewpoints and `this` types, `_` nominals, match completeness,
  operator precedence, value formal parameters, capability positions,
  locals and embeds, lambdas and their captures, compile intrinsics
  and errors, semicolon placement, FFI legality, ifdef and use-guard
  condition shapes, annotation placement, constraints, consume shapes,
  returns, and casts.
  """
  fun apply(
    file: String val,
    tree: SyntaxTree val,
    at: Array[USize] val)
    : Array[CheckDiagnostic] val
  =>
    recover val
      let out = Array[CheckDiagnostic]
      let d = _Diags(file, tree, at, out)

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

      for (element, depth, _, kind, _) in tree.walk() do
        stack.truncate(depth)
        if kind is NdClassDef then
          _entity(d, element)
          if _is_default_method_entity(tree, element) then
            default_method_scope = element + (try
              tree.subtree_size(element)?
            else
              0
            end)
          end
        elseif kind is NdObject then
          _object(d, element)
        elseif kind is NdUseFFI then
          _ffi(d, element, true)
        elseif kind is NdFFICall then
          _ffi(d, element, false)
          if element < default_method_scope then
            d.report(element,
              "Can't call an FFI function in a default method or behavior")
          end
        elseif (kind is NdBareLambda) or (kind is NdBareLambdaType) then
          _bare_lambda(d, element)
          _lambda(d, element)
        elseif kind is NdLambda then
          _lambda(d, element)
        elseif kind is NdIfDef then
          _ifdef_flags(d, element)
        elseif kind is NdUse then
          _use_rules(d, element)
        elseif kind is NdSeq then
          _seq(d, element, stack)
        elseif kind is TkEllipsis then
          _ellipsis(d, element, stack)
        elseif kind is NdViewpoint then
          if in_constraint(element) then
            d.report(_anchor(tree, element),
              "arrow types can't be used as type constraints")
          end
          _viewpoint_right(d, element)
        elseif kind is NdTupleType then
          if in_tp_constraint(element) then
            d.report(_anchor(tree, element),
              "tuple types can't be used as type constraints")
          end
        elseif kind is NdNominal then
          _gencap_outside_constraint(d, element, gencap_constraint)
          _nominal_dontcare(d, element)
        elseif kind is NdThisType then
          _thistype(d, element, stack)
        elseif kind is NdMatch then
          _match_last_case(d, element)
        elseif kind is NdBinOp then
          _infix_precedence(d, element)
        elseif kind is NdInfixType then
          _type_infix_mix(d, element)
        elseif kind is NdValueFormalArg then
          let parent =
            try stack(stack.size() - 1)?._1 else element end
          d.report_with_info(element,
            "Value formal parameters not yet supported",
            "Note that many functions including array indexing use the " +
              "apply method rather than square brackets"
            where info_element = parent)
        elseif kind is NdConstExpr then
          d.report(element, "Compile time expressions not yet supported")
        elseif (kind is TkIso) or (kind is TkTrn) or (kind is TkRef) or
          (kind is TkVal) or (kind is TkBox) or (kind is TkTag)
        then
          _cap_as_type(d, element, stack)
        elseif kind is NdLocal then
          match _id_of(tree, element)
          | let id: USize =>
            _check_id(d, id, "local variable"
              where start_lower = true, allow_underscore = true,
                allow_tick = true, allow_dontcare = true)
          end
          try
            for child in tree.children(element)? do
              if tree.kind(child)? is TkEmbed then
                d.report(element, "Local variables cannot be embedded")
              end
            end
          end
        elseif kind is NdTypeParam then
          match _id_of(tree, element)
          | let id: USize =>
            _check_id(d, id, "type parameter" where start_upper = true)
          end
        elseif kind is NdMethod then
          _method_params(d, element)
        elseif kind is NdLambdaParam then
          match _id_of(tree, element)
          | let id: USize =>
            // A `_` lambda parameter is legal whenever type
            // inference can substitute it from an antecedent type,
            // which this checker cannot see — so `_` is allowed
            // here whatever the annotation, and a typed `_` with no
            // antecedent is an accepted fail-open miss.
            _check_id(d, id, "parameter"
              where start_lower = true, allow_underscore = true,
                allow_tick = true, allow_dontcare = true)
          end
        elseif kind is NdConsume then
          _consume(d, element)
        elseif kind is NdAsOp then
          _cast(d, element)
        elseif kind is NdAnnotations then
          _annotations(d, element, stack)
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
    d: _Diags,
    element: USize,
    is_declaration: Bool)
  =>
    let tree = d.tree
    try
      var i = element + 1
      let size = tree.subtree_size(element)?
      while i < (element + size) do
        if tree.kind(i)? is NdNamedArgs then
          d.report(i, "FFIs cannot take named arguments")
        end
        i = i + (try tree.subtree_size(i)? else 1 end)
      end
    end
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
            d.report(child,
              "FFI functions must specify a single return type")
          end
        | TkQuestion =>
          d.report(child,
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
                    d.report(_anchor(tree, part),
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
    d: _Diags,
    element: USize,
    stack: Array[(USize, SyntaxKind)] box)
  =>
    let tree = d.tree
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
      d.report(element,
        "... may only appear in FFI declarations")
    end
    // Last parameter: no parameter node after this token.
    try
      var after = false
      for child in tree.children(params)? do
        if child == element then
          after = true
        elseif after and (tree.kind(child)? is NdParam) then
          d.report(element,
            "... must be the last parameter")
          break
        end
      end
    end

  fun _bare_lambda(
    d: _Diags,
    element: USize)
  =>
    let tree = d.tree
    var after_body = false
    try
      for child in tree.children(element)? do
        match tree.kind(child)?
        | TkRbrace => after_body = true
        | NdTypeParams =>
          d.report(child,
            "a bare lambda cannot specify type parameters")
        | NdLambdaCaptures =>
          d.report(child,
            "a bare lambda cannot specify captures")
        | TkIso | TkTrn | TkRef | TkBox | TkTag =>
          if after_body then
            d.report(child,
              "a bare lambda can only have a 'val' capability")
          else
            d.report(child,
              "a bare lambda cannot specify a receiver capability")
          end
        | TkVal =>
          if not after_body then
            d.report(child,
              "a bare lambda cannot specify a receiver capability")
          end
        end
      end
    end

  fun _method_params(d: _Diags, method: USize) =>
    """
    ponyc's check_id_param, attached where ponyc attaches it:
    check_params' one caller checks a method's parameter list, so a
    parameter anywhere else — an FFI declaration's — is never
    checked. Lambda parameters take the rule separately, after the
    desugar's antecedent substitution.
    """
    let tree = d.tree
    try
      for child in tree.children(method)? do
        if tree.kind(child)? is NdParams then
          for param in tree.children(child)? do
            if tree.kind(param)? is NdParam then
              match _id_of(tree, param)
              | let id: USize =>
                _check_id(d, id, "parameter"
                  where start_lower = true, allow_underscore = true,
                    allow_tick = true)
              end
            end
          end
        end
      end
    end

  fun _check_id(
    d: _Diags,
    id: USize,
    desc: String val,
    start_upper: Bool = false,
    start_lower: Bool = false,
    allow_leading_underscore: Bool = false,
    allow_underscore: Bool = false,
    allow_tick: Bool = false,
    allow_dontcare: Bool = false)
  =>
    """
    ponyc's `check_id` (`ast/id.c`): the character rules a name obeys,
    with the position's spec passed the way id.c's flag word is.
    """
    let full = d.text(id)
    var name = full
    var prev: U8 = 0
    if try full(0)? == '$' else false end then
      // Placed by the compiler; id.c trusts it.
      return
    end
    if try full(0)? == '_' else false end then
      name = full.substring(1)
      prev = '_'
      if name.size() == 0 then
        if not allow_dontcare then
          d.report(id, desc + " name cannot be \"" + full + "\"")
        end
        return
      end
      if not allow_leading_underscore then
        d.report(id,
          desc + " name \"" + full + "\" cannot start with underscores")
        return
      end
    end
    let first = try name(0)? else 0 end
    if start_lower and ((first < 'a') or (first > 'z')) then
      if not allow_leading_underscore then
        d.report(id, desc + " name \"" + full + "\" must start a-z")
      else
        d.report(id,
          desc + " name \"" + full + "\" must start a-z or _(a-z)")
      end
      return
    end
    if start_upper and ((first < 'A') or (first > 'Z')) then
      if not allow_leading_underscore then
        d.report(id, desc + " name \"" + full + "\" must start A-Z")
      else
        d.report(id,
          desc + " name \"" + full + "\" must start A-Z or _(A-Z)")
      end
      return
    end
    var i: USize = 0
    while i < name.size() do
      let c = try name(i)? else 0 end
      if c == '\'' then
        break
      end
      if c == '_' then
        if not allow_underscore then
          d.report(id,
            desc + " name \"" + full + "\" cannot contain underscores")
          return
        end
        if prev == '_' then
          d.report(id, desc + " name \"" + full +
            "\" cannot contain double underscores")
          return
        end
      end
      prev = c
      i = i + 1
    end
    if prev == '_' then
      d.report(id,
        desc + " name \"" + full + "\" cannot have a trailing underscore")
      return
    end
    if i == name.size() then
      return
    end
    if not allow_tick then
      d.report(id,
        desc + " name \"" + full + "\" cannot contain prime (')")
      return
    end
    while i < name.size() do
      if try name(i)? != '\'' else true end then
        d.report(id, "prime(') can only appear at the end of " + desc +
          " name \"" + full + "\"")
        return
      end
      i = i + 1
    end

  fun _id_of(tree: SyntaxTree val, parent: USize): (USize | None) =>
    """
    The first identifier child of `parent`.
    """
    try
      for child in tree.children(parent)? do
        if tree.kind(child)? is TkId then
          return child
        end
      end
    end
    None

  fun _thistype(
    d: _Diags,
    element: USize,
    stack: Array[(USize, SyntaxKind)] box)
  =>
    """
    ponyc's `syntax_thistype`: in a type, `this` is only a viewpoint,
    only in a method, and only in a box function.
    """
    let tree = d.tree
    let parent_kind =
      try stack(stack.size() - 1)?._2 else NdModule end
    if not (parent_kind is NdViewpoint) then
      d.report(element,
        "in a type, 'this' can only be used as a viewpoint")
    end
    var i = stack.size()
    while i > 0 do
      i = i - 1
      (let el, let kind) = try stack(i)? else return end
      if kind is NdMethod then
        try
          var named = false
          for child in tree.children(el)? do
            match tree.kind(child)?
            | TkId => named = true
            | TkIso | TkTrn | TkRef | TkVal | TkTag =>
              if not named then
                d.report(element,
                  "can only use 'this' for a viewpoint in a box function")
                return
              end
            end
          end
        end
        return
      end
    end
    d.report(element,
      "can only use 'this' for a viewpoint in a method")

  fun _viewpoint_right(d: _Diags, element: USize) =>
    """
    ponyc's `syntax_arrow` right-hand clauses: neither `this` nor a
    refcap may appear to the right of a viewpoint.
    """
    let tree = d.tree
    try
      var after_arrow = false
      for child in tree.children(element)? do
        match tree.kind(child)?
        | TkWhitespace | TkLineComment | TkNestedComment => None
        | TkArrow => after_arrow = true
        | NdThisType =>
          if after_arrow then
            d.report(_anchor(tree, element),
              "'this' cannot appear to the right of a viewpoint")
            return
          end
        | TkIso | TkTrn | TkRef | TkVal | TkBox | TkTag =>
          if after_arrow then
            d.report(_anchor(tree, element),
              "refcaps cannot appear to the right of a viewpoint")
            return
          end
        end
      end
    end

  fun _nominal_dontcare(d: _Diags, element: USize) =>
    """
    ponyc's `syntax_nominal`: a `_` type takes no package, no type
    arguments, no capability, and no modifier.
    """
    let tree = d.tree
    try
      var package: (USize | None) = None
      var name: (USize | None) = None
      var typeargs: (USize | None) = None
      var cap: (USize | None) = None
      var eph: (USize | None) = None
      for child in tree.children(element)? do
        match tree.kind(child)?
        | TkId =>
          match name
          | None => name = child
          | let first: USize =>
            package = first
            name = child
          end
        | NdTypeArgs => typeargs = child
        | TkIso | TkTrn | TkRef | TkVal | TkBox | TkTag
        | TkCapRead | TkCapSend | TkCapShare | TkCapAlias | TkCapAny =>
          cap = child
        | TkEphemeral | TkAliased => eph = child
        end
      end
      match name
      | let id: USize if d.text(id) == "_" =>
        match package
        | let p: USize =>
          // CheckNames' qualified-`_` guard in names.pony relies on
          // this report existing: it returns silently there because
          // this rung closes the ladder first.
          d.report(p, "'_' cannot be in a package")
        end
        match typeargs
        | let t: USize => d.report(t, "'_' cannot have generic arguments")
        end
        match cap
        | let c: USize => d.report(c, "'_' cannot specify capability")
        end
        match eph
        | let e: USize =>
          d.report(e, "'_' cannot specify capability modifier")
        end
      end
    end

  fun _match_last_case(d: _Diags, element: USize) =>
    """
    ponyc's `syntax_match`: the last case must have a body.
    """
    let tree = d.tree
    try
      for child in tree.children(element)? do
        if tree.kind(child)? is NdCases then
          var last: (USize | None) = None
          for c in tree.children(child)? do
            if tree.kind(c)? is NdCase then
              last = c
            end
          end
          match last
          | let case_el: USize =>
            var has_body = false
            for part in tree.children(case_el)? do
              if tree.kind(part)? is TkDblarrow then
                has_body = true
              end
            end
            if not has_body then
              d.report(case_el, "Last case in match must have a body")
            end
          end
        end
      end
    end

  fun _infix_precedence(d: _Diags, element: USize) =>
    """
    ponyc's `syntax_infix_expr`: mixing different binary operators
    without parentheses is an error — Pony has no precedence. This
    tree nests an unparenthesised chain directly, so a binary operand
    that is itself a binary node with a different operator is the
    mixed chain; parentheses wrap the operand in a group and exempt
    it.
    """
    let tree = d.tree
    try
      let at =
        match _binop_token(tree, element)
        | let t: USize => t
        | None => return
        end
      let op = tree.kind(at)?
      for child in tree.children(element)? do
        if tree.kind(child)? is NdBinOp then
          match _binop_token(tree, child)
          | let t: USize =>
            if not (tree.kind(t)? is op) then
              d.report(at,
                "Operator precedence is not supported. " +
                  "Parentheses required.")
              return
            end
          end
        end
      end
    end

  fun _binop_token(tree: SyntaxTree val, element: USize): (USize | None) =>
    try
      let size = tree.subtree_size(element)?
      // Direct children only: each step skips a whole subtree.
      var i = element + 1
      while i < (element + size) do
        match tree.kind(i)?
        | TkAnd | TkOr | TkXor
        | TkPlus | TkMinus | TkMultiply | TkDivide | TkRem | TkMod
        | TkPlusTilde | TkMinusTilde | TkMultiplyTilde
        | TkDivideTilde | TkRemTilde | TkModTilde
        | TkLshift | TkRshift | TkLshiftTilde | TkRshiftTilde
        | TkIs | TkIsnt
        | TkEq | TkNe | TkLt | TkLe | TkGe | TkGt
        | TkEqTilde | TkNeTilde | TkLtTilde | TkLeTilde
        | TkGeTilde | TkGtTilde =>
          return i
        end
        i = i + (try tree.subtree_size(i)? else 1 end)
      end
    end
    None

  fun _type_infix_mix(d: _Diags, element: USize) =>
    """
    ponyc's precedence rule on type operators: a union and an
    intersection cannot mix without parentheses. This tree keeps an
    unparenthesised type chain flat, so the mix is both operators in
    one infix-type node.
    """
    let tree = d.tree
    try
      var first: (SyntaxKind | None) = None
      for child in tree.children(element)? do
        match tree.kind(child)?
        | TkPipe | TkIsecttype =>
          match first
          | None => first = tree.kind(child)?
          | let f: SyntaxKind =>
            if not (tree.kind(child)? is f) then
              d.report(child,
                "Operator precedence is not supported. " +
                  "Parentheses required.")
              return
            end
          end
        end
      end
    end

  fun _cap_as_type(
    d: _Diags,
    element: USize,
    stack: Array[(USize, SyntaxKind)] box)
  =>
    """
    ponyc's `syntax_cap`: a bare capability is not a type. The parents
    a capability may sit under are the constructs that take one — a
    nominal's suffix, a viewpoint, an entity or method or lambda
    header, a recover or consume — and anywhere else it is a type made
    of nothing but a capability.
    """
    let parent_kind =
      try stack(stack.size() - 1)?._2 else NdModule end
    match parent_kind
    | NdNominal | NdViewpoint | NdObject | NdLambda | NdBareLambda
    | NdRecover | NdConsume | NdMethod | NdClassDef | NdLambdaType
    | NdBareLambdaType =>
      None
    else
      d.report(element, "a type cannot be only a capability")
    end

  fun _lambda(d: _Diags, element: USize) =>
    """
    ponyc's `syntax_lambda` clauses shared by both lambda forms: the
    return type cannot be a capability, and `this` is captured by
    name, never bare.
    """
    let tree = d.tree
    try
      var after_colon = false
      for child in tree.children(element)? do
        match tree.kind(child)?
        | TkWhitespace | TkLineComment | TkNestedComment => None
        | TkColon => after_colon = true
        | TkDblarrow => after_colon = false
        | TkIso | TkTrn | TkRef | TkVal | TkBox | TkTag =>
          if after_colon then
            d.report_with_info(child,
              "lambda return type: " + d.text(child),
              "lambda return type cannot be capability")
            after_colon = false
          end
        | NdLambdaCaptures =>
          for capture in tree.children(child)? do
            match tree.kind(capture)?
            | NdThis =>
              d.report(capture, "use a named capture to capture 'this'")
            | NdLambdaCapture =>
              var typed = false
              var valued = false
              for part in tree.children(capture)? do
                match tree.kind(part)?
                | TkColon => typed = true
                | TkAssign => valued = true
                end
              end
              if typed and (not valued) then
                d.report(capture, "value missing for lambda expression " +
                  "capture (cannot specify type without value)")
              end
            end
          end
        else
          if after_colon then
            after_colon = false
          end
        end
      end
    end

  fun _annotation_location(
    d: _Diags,
    name_el: USize,
    name: String val,
    stack: Array[(USize, SyntaxKind)] box)
  =>
    """
    ponyc's `check_annotation_location`: the annotations with placement
    rules, each checked against the node the annotation sits on.
    """
    let tree = d.tree
    (let parent, let parent_kind) =
      try stack(stack.size() - 1)? else return end
    if (name == "likely") or (name == "unlikely") then
      let ok =
        match parent_kind
        | NdIf | NdWhile | NdCase => true
        | NdRepeat =>
          // Only the until clause takes it, not the loop body.
          var seen_until = false
          try
            for child in tree.children(parent)? do
              if tree.kind(child)? is TkUntil then
                seen_until = true
              elseif (child <= name_el) and
                (name_el < (child + tree.subtree_size(child)?))
              then
                break
              end
            end
          end
          seen_until
        else
          false
        end
      if not ok then
        d.report(name_el,
          "a '" + name + "' annotation can only appear on the condition " +
            "of an if, while, or until, or on the case of a match")
      end
    elseif name == "packed" then
      if not _entity_keyword_is(tree, parent, parent_kind, TkStruct) then
        d.report(name_el,
          "a 'packed' annotation can only appear on a struct declaration")
      end
    elseif name == "nosupertype" then
      if (not _entity_keyword_is(tree, parent, parent_kind, TkClass)) and
        (not _entity_keyword_is(tree, parent, parent_kind, TkActor)) and
        (not _entity_keyword_is(tree, parent, parent_kind, TkPrimitive))
        and (not _entity_keyword_is(tree, parent, parent_kind, TkStruct))
      then
        d.report(name_el,
          "a 'nosupertype' annotation can only appear on a concrete " +
            "type declaration")
      end
    elseif name == "exhaustive" then
      if not (parent_kind is NdMatch) then
        d.report(name_el,
          "an 'exhaustive' annotation can only appear on a match " +
            "expression")
      end
    elseif name == "nodoc" then
      let ok =
        match parent_kind
        | NdMethod => true
        | NdClassDef =>
          not _entity_keyword_is(tree, parent, parent_kind, TkType)
        else
          false
        end
      if not ok then
        d.report(name_el, "'nodoc' annotation isn't valid here")
      end
    elseif name == "c_api" then
      _c_api_annotation(d, name_el, parent, parent_kind)
    end

  fun _entity_keyword_is(
    tree: SyntaxTree val,
    parent: USize,
    parent_kind: SyntaxKind,
    keyword: TokenKind)
    : Bool
  =>
    if not (parent_kind is NdClassDef) then
      return false
    end
    try
      for child in tree.children(parent)? do
        match tree.kind(child)?
        | TkActor | TkClass | TkStruct | TkPrimitive | TkTrait
        | TkInterface | TkType =>
          return tree.kind(child)? is keyword
        end
      end
    end
    false

  fun _c_api_annotation(
    d: _Diags,
    name_el: USize,
    parent: USize,
    parent_kind: SyntaxKind)
  =>
    """
    ponyc's `c_api` annotation rules: only concrete types and type
    aliases export, an exported alias needs a single nominal target,
    generics and private names cannot export.
    """
    let tree = d.tree
    if not (parent_kind is NdClassDef) then
      d.report(name_el, "'c_api' annotation isn't valid here")
      return
    end
    if _entity_keyword_is(tree, parent, parent_kind, TkTrait) or
      _entity_keyword_is(tree, parent, parent_kind, TkInterface)
    then
      d.report(name_el, "traits and interfaces cannot be exported")
      return
    end
    try
      var name_id: (USize | None) = None
      var typeparams: (USize | None) = None
      var provides: (USize | None) = None
      for child in tree.children(parent)? do
        match tree.kind(child)?
        | TkId => if name_id is None then name_id = child end
        | NdTypeParams => typeparams = child
        | NdProvides => provides = child
        end
      end
      if _entity_keyword_is(tree, parent, parent_kind, TkType) then
        match provides
        | None =>
          d.report(name_el, "exported type alias must have a target type")
          return
        | let pr: USize =>
          var target_ok = false
          for child in tree.children(pr)? do
            match tree.kind(child)?
            | TkIs | NdError
            | TkWhitespace | TkLineComment | TkNestedComment => None
            | NdNominal => target_ok = true
            else
              target_ok = false
            end
          end
          if not target_ok then
            d.report(name_el,
              "only type aliases for a single concrete type can be " +
                "exported")
            return
          end
        end
      end
      if typeparams isnt None then
        d.report(name_el,
          "generic types cannot be exported directly; export a concrete " +
            "reification via a type alias")
        return
      end
      match name_id
      | let id: USize =>
        let name = d.text(id)
        if (try name(0)? == '_' else false end) and (name.size() > 1) then
          d.report(name_el, "only public types can be exported")
        end
      end
    end

  fun _ifdef_flags(
    d: _Diags,
    ifdef_el: USize)
  =>
    """
    Run the condition-shape rules over each condition of an `ifdef`.
    """
    let tree = d.tree
    try
      var in_condition = false
      for child in tree.children(ifdef_el)? do
        match tree.kind(child)?
        | TkIfdef | TkElseif => in_condition = true
        | TkWhitespace | TkLineComment | TkNestedComment => None
        | NdAnnotations => None
        | TkThen => in_condition = false
        else
          if in_condition then
            _cond_shape(d, child, "ifdef condition")
            in_condition = false
          end
        end
      end
    end

  fun _use_rules(
    d: _Diags,
    use_el: USize)
  =>
    """
    The `use` rules ponyc's syntax pass makes: an FFI `use` takes no
    alias, an alias is a package name, and a guard is shaped like an
    ifdef condition.
    """
    let tree = d.tree
    try
      var in_guard = false
      var alias: (USize | None) = None
      var ffi = false
      for child in tree.children(use_el)? do
        match tree.kind(child)?
        | NdUseName => alias = child
        | NdUseFFI => ffi = true
        | TkIf => in_guard = true
        | TkWhitespace | TkLineComment | TkNestedComment => None
        else
          if in_guard then
            _cond_shape(d, child, "use guard")
            in_guard = false
          end
        end
      end
      match alias
      | let a: USize =>
        if ffi then
          d.report(a, "Use FFI may not have an alias")
        else
          match _id_of(tree, a)
          | let id: USize =>
            _check_id(d, id, "package"
              where start_lower = true, allow_underscore = true)
          end
        end
      end
    end

  fun _cond_shape(
    d: _Diags,
    element: USize,
    context: String val)
    : Bool
  =>
    """
    ponyc's `syntax_ifdef_cond`: a condition is built of and, or and
    not over build flags, with parentheses around a single expression;
    any other shape is invalid.
    """
    let tree = d.tree
    try
      match tree.kind(element)?
      | NdBinOp =>
        // A binary node built by anything but `and` or `or` is invalid
        // whole, at its operator, which is where ponyc's node sits.
        match _binop_token(tree, element)
        | let t: USize =>
          match tree.kind(t)?
          | TkAnd | TkOr => None
          else
            d.report(t, "Invalid " + context)
            return false
          end
        end
        for child in tree.children(element)? do
          match tree.kind(child)?
          | TkAnd | TkOr | TkQuestion
          | TkWhitespace | TkLineComment | TkNestedComment => None
          | TkString =>
            if not _flag_string(d, child) then
              return false
            end
          else
            if tree.is_leaf(child)? then
              d.report(child, "Invalid " + context)
              return false
            end
            if not _cond_shape(d, child, context) then
              return false
            end
          end
        end
      | NdUnaryOp =>
        for child in tree.children(element)? do
          match tree.kind(child)?
          | TkNot
          | TkWhitespace | TkLineComment | TkNestedComment => None
          | TkString =>
            if not _flag_string(d, child) then
              return false
            end
          else
            if tree.is_leaf(child)? then
              d.report(child, "Invalid " + context)
              return false
            end
            if not _cond_shape(d, child, context) then
              return false
            end
          end
        end
      | NdRef =>
        match _id_of(tree, element)
        | let id: USize =>
          let name = d.text(id)
          if not _Platforms.known(name) then
            d.report(element,
              "\"" + name + "\" is not a valid platform flag\n")
            return false
          end
        end
      | TkString =>
        return _flag_string(d, element)
      | NdGrouped | NdSeq =>
        var statements: USize = 0
        var only: (USize | None) = None
        for child in tree.children(element)? do
          match tree.kind(child)?
          | TkLparen | TkLparenNew | TkRparen | TkSemi
          | TkWhitespace | TkLineComment | TkNestedComment => None
          else
            statements = statements + 1
            only = child
          end
        end
        if (tree.kind(element)? is NdSeq) and (statements != 1) then
          d.report(element, "Sequence not allowed in " + context)
          return false
        end
        match only
        | let child: USize =>
          if not _cond_shape(d, child, context) then
            return false
          end
        end
      else
        d.report(element, "Invalid " + context)
        return false
      end
    end
    true

  fun _flag_string(d: _Diags, element: USize): Bool =>
    """
    A string in a condition is a user build flag, which must not be a
    platform name or a reserved flag.
    """
    let name = StringLiteralValue(d.text(element))
    if _Platforms.known(name.lower()) or _Platforms.illegal(name.lower())
    then
      d.report(element,
        "\"" + name + "\" is not a valid user build flag\n")
      false
    else
      true
    end

  fun _seq(
    d: _Diags,
    seq: USize,
    stack: Array[(USize, SyntaxKind)] box)
  =>
    """
    Rules about a sequence's own children: semicolons separate expressions
    on the same line and nothing else, and the compile intrinsics and
    errors may only be a body, whole.
    """
    let tree = d.tree
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
          if d.text(child).contains("\n") then
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
            d.report(child,
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
                if d.text(j).contains("\n") then
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
            d.report(child,
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
              d.report(child,
                "Use a semi colon to separate expressions on the same " +
                  "line")
            end
          end
          prev_stmt = child
          semi_since_prev = false
          newline_since_prev = false

          if kind is NdJump then
            _jump(d, child, seq, stack, parent_kind,
            grandparent_kind)
          end
        end
      end
    end

  fun _jump(
    d: _Diags,
    jump: USize,
    seq: USize,
    stack: Array[(USize, SyntaxKind)] box,
    parent_kind: SyntaxKind,
    grandparent_kind: SyntaxKind)
  =>
    let tree = d.tree
    var keyword: (SyntaxKind | None) = None
    var value: (USize | None) = None
    var is_return = false
    try
      for child in tree.children(jump)? do
        match tree.kind(child)?
        | TkCompileIntrinsic => keyword = TkCompileIntrinsic
        | TkCompileError => keyword = TkCompileError
        | TkReturn =>
          keyword = TkReturn
          is_return = true
        | TkBreak => keyword = TkReturn
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
                d.report(part, "Unreachable code")
                reported = true
                break
              end
            end
          end
        end
      end
      if (not reported) and is_return then
        reported = not _return_rules(d, jump, value, stack)
      end
      if not reported then
        _climb_unreachable(d, jump, seq, stack)
      end
      return
    end

    match keyword
    | TkCompileIntrinsic =>
      if not (parent_kind is NdMethod) then
        d.report(jump,
          "a compile intrinsic must be a method body")
      elseif (value isnt None) or
        (not _sole_statement(tree, seq, jump where allow_docstring = true))
      then
        d.report(jump,
          "a compile intrinsic must be the entire body")
      end
    | TkCompileError =>
      let in_ifdef =
        (parent_kind is NdIfDef) or
          (((parent_kind is NdThen) or (parent_kind is NdElse)) and
            (grandparent_kind is NdIfDef))
      if not in_ifdef then
        d.report(jump,
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
        d.report(jump,
          "a compile error must have a string literal reason for the error")
      elseif not
        _sole_statement(tree, seq, jump where allow_docstring = false)
      then
        d.report(jump,
          "a compile error must be the entire ifdef clause")
      end
    end

  fun _return_rules(
    d: _Diags,
    jump: USize,
    value: (USize | None),
    stack: Array[(USize, SyntaxKind)] box)
    : Bool
  =>
    """
    ponyc's `return`-only clauses: a return sits in a method body, and
    one in a constructor or behaviour carries no value unless a lambda
    body intervenes. Returns whether the return is legal, because
    ponyc stops at the first of these.
    """
    let tree = d.tree
    var method: (USize | None) = None
    var through_lambda = false
    var outside_body = false
    var i = stack.size()
    while i > 0 do
      i = i - 1
      (let el, let kind) = try stack(i)? else return true end
      match kind
      | NdLambda | NdBareLambda => through_lambda = true
      | NdParam | NdDefaultArg | NdField => outside_body = true
      | NdMethod =>
        method = el
        break
      end
    end
    if (method is None) or outside_body then
      d.report(jump, "return must occur in a method body")
      return false
    end
    var has_value = false
    match value
    | let v: USize =>
      try
        for part in tree.children(v)? do
          match tree.kind(part)?
          | TkWhitespace | TkLineComment | TkNestedComment
          | TkSemi => None
          else
            has_value = true
          end
        end
      end
    end
    if has_value and (not through_lambda) then
      match method
      | let m: USize =>
        try
          for child in tree.children(m)? do
            match tree.kind(child)?
            | TkBe | TkNew =>
              d.report(jump,
                "A return in a constructor or a behaviour can't return " +
                  "a value")
              return false
            | TkFun => return true
            end
          end
        end
      end
    end
    true

  fun _climb_unreachable(
    d: _Diags,
    jump: USize,
    seq: USize,
    stack: Array[(USize, SyntaxKind)] box)
  =>
    """
    ponyc's second unreachable-code clause: from the jump, walk the
    enclosing sequence chain outward and report the first statement
    that follows at any level, stepping through a parenthesised group,
    which ponyc's tree has no node for.
    """
    let tree = d.tree
    var current = jump
    var parent = seq
    var parent_kind: SyntaxKind = NdSeq
    var i = stack.size()
    try
      while true do
        if parent_kind is NdSeq then
          match _next_statement(tree, parent, current)?
          | let sibling: USize =>
            d.report(sibling, "Unreachable code")
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
    d: _Diags,
    element: USize)
  =>
    let tree = d.tree
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
            name = d.text(child)
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
        d.report(tp,
          "the Main actor cannot have type parameters")
      end
      if _EntityPerm.main(ent) == 'N' then
        d.report(element, "Main must be an actor")
      end
    end
    match name_i
    | let id: USize =>
      _check_id(d, id, desc
        where start_upper = true, allow_leading_underscore = true)
    end
    match defcap
    | let cap: USize if _EntityPerm.cap(ent) == 'N' =>
      d.report(cap,
        desc + " cannot specify default capability")
    end
    match c_api
    | let bare: USize =>
      if _EntityPerm.c_api(ent) == 'N' then
        d.report(bare, desc + " cannot specify C api")
      end
      match typeparams
      | let tp: USize =>
        d.report(tp,
          "generic actor cannot specify C api")
      end
    end
    if ent is _TypeAlias then
      if provides is None then
        match name_i
        | let id: USize =>
          d.report(id, "a type alias must specify a type")
        end
      end
    else
      match provides
      | let pr: USize =>
        if _has_annotation(d, element, "nosupertype") then
          d.report(_anchor(tree, pr),
            "a 'nosupertype' type cannot specify a provides list")
        else
          _provides(d, pr)
        end
      end
    end
    match members
    | let ms: USize =>
      _members(d, ent, ms)
    end

  fun _has_annotation(
    d: _Diags,
    element: USize,
    name: String val)
    : Bool
  =>
    let tree = d.tree
    try
      for child in tree.children(element)? do
        if tree.kind(child)? is NdAnnotations then
          for part in tree.children(child)? do
            if tree.kind(part)? is TkId then
              if d.text(part) == name then
                return true
              end
            end
          end
        end
      end
    end
    false

  fun _members(
    d: _Diags,
    ent: _EntityKind,
    members: USize)
  =>
    let tree = d.tree
    try
      for member in tree.children(members)? do
        match tree.kind(member)?
        | NdField =>
          if _EntityPerm.field(ent) == 'N' then
            d.report(member,
              "Can't have fields in " + _EntityDesc(ent))
          end
          match _id_of(tree, member)
          | let id: USize =>
            _check_id(d, id, "field"
              where start_lower = true, allow_leading_underscore = true,
                allow_underscore = true, allow_tick = true)
          end
        | NdMethod =>
          _method(d, ent, member)
        end
      end
    end

  fun _method(
    d: _Diags,
    ent: _EntityKind,
    method: USize)
  =>
    let tree = d.tree
    var found: (_MethodKind | None) = None
    var cap: (USize | None) = None
    var bare: (USize | None) = None
    var ret: (USize | None) = None
    var err: (USize | None) = None
    var body = false
    var body_el: (USize | None) = None
    var docstring: (USize | None) = None
    var ret_cap: (USize | None) = None
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
          if not named then
            cap = child
          elseif after_colon then
            ret = child
            ret_cap = child
            after_colon = false
          end
        | TkAt => if not named then bare = child end
        | TkId => named = true
        | TkColon =>
          ret = child
          after_colon = true
        | TkQuestion => err = child
        | TkString => if not body then docstring = child end
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
      d.report(method, desc + "s are not allowed")
      return
    | let perms: String val =>
      _element(d, perms, 0, cap, method, "receiver capability", desc)
      _element(d, perms, 1, bare, method, "bareness", desc)
      _element(d, perms, 2, ret, method, "return type", desc)
      _element(d, perms, 3, err, method, "?", desc)
      let body_at: (USize | None) =
        if body then
          match body_el
          | let el: USize => el
          | None => method
          end
        else
          None
        end
      _element(d, perms, 4, body_at, method, "body", desc)
    end
    match _id_of(tree, method)
    | let id: USize =>
      _check_id(d, id, "method"
        where start_lower = true, allow_leading_underscore = true,
          allow_underscore = true)
    end
    match docstring
    | let doc: USize if body =>
      d.report(doc, "methods with bodies must put docstrings in the body")
    end
    match ret_cap
    | let cap_el: USize if mkind is _Fun =>
      d.report_with_info(cap_el,
        "function return type: " + d.text(cap_el),
        "function return type cannot be capability")
    end

  fun _element(
    d: _Diags,
    perms: String val,
    index: USize,
    actual: (USize | None),
    report_at: USize,
    context: String val,
    desc: String val)
  =>
    let permission = try perms(index)? else _Unreachable(); 'X' end
    if (permission == 'N') and (actual isnt None) then
      match actual
      | let el: USize =>
        d.report(el,
          desc + " cannot specify " + context)
      end
    elseif (permission == 'Y') and (actual is None) then
      d.report(report_at,
        desc + " must specify " + context)
    end

  fun _provides(
    d: _Diags,
    provides: USize)
  =>
    let tree = d.tree
    try
      for child in tree.children(provides)? do
        match tree.kind(child)?
        | TkIs | NdError
        | TkWhitespace | TkLineComment | TkNestedComment => None
        else
          _provides_type(d, child)
        end
      end
    end

  fun _provides_type(
    d: _Diags,
    element: USize)
  =>
    """
    ponyc's `check_provides_type`: a provides type is a nominal without a
    capability, an intersection of such, or parentheses around one. A `|`
    in an infix type, or any other type shape, is invalid there.
    """
    let tree = d.tree
    try
      match tree.kind(element)?
      | NdNominal =>
        for child in tree.children(element)? do
          match tree.kind(child)?
          | TkIso | TkTrn | TkRef | TkVal | TkBox | TkTag
          | TkCapRead | TkCapSend | TkCapShare | TkCapAlias | TkCapAny =>
            d.report(child,
              "can't specify a capability in a provides type")
          | TkEphemeral | TkAliased =>
            d.report(child,
              "can't specify ephemeral in a provides type")
          end
        end
      | NdInfixType =>
        for child in tree.children(element)? do
          match tree.kind(child)?
          | TkPipe =>
            d.report(child, invalid_provides())
            return
          | NdNominal | NdGroupedType | NdInfixType =>
            _provides_type(d, child)
          | TkIsecttype => None
          | TkWhitespace | TkLineComment | TkNestedComment =>
            // The tree is lossless, so trivia are children here too.
            None
          else
            d.report(element, invalid_provides())
            return
          end
        end
      | NdGroupedType =>
        for child in tree.children(element)? do
          match tree.kind(child)?
          | TkLparen | TkLparenNew | TkRparen | NdError
          | TkWhitespace | TkLineComment | TkNestedComment => None
          else
            _provides_type(d, child)
          end
        end
      else
        d.report(_anchor(tree, element),
          invalid_provides())
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
        | NdProvides =>
          // ponyc's provides node sits at its first type, past `is`.
          for child in tree.children(element)? do
            match tree.kind(child)?
            | TkIs | TkWhitespace | TkLineComment
            | TkNestedComment => None
            else
              return child
            end
          end
          return element
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

  fun invalid_provides(): String val =>
    """
    ponyc's invalid-provides wording — shared with `CheckProvides`,
    which raises the same rule for shapes the syntax pass cannot
    see.
    """
    "invalid provides type. Can only be interfaces, traits and intersects " +
      "of those."

  fun _object(
    d: _Diags,
    obj: USize)
  =>
    """
    ponyc's `syntax_object`: an object literal's members go through the
    actor permission tables, its provides list through the provides
    rules, and its fields must carry an initialiser.
    """
    let tree = d.tree
    try
      for child in tree.children(obj)? do
        match tree.kind(child)?
        | NdProvides => _provides(d, child)
        | NdMembers =>
          _members(d, _Actor, child)
          for member in tree.children(child)? do
            if tree.kind(member)? is NdField then
              var initialised = false
              for part in tree.children(member)? do
                if tree.kind(part)? is TkAssign then
                  initialised = true
                end
              end
              if not initialised then
                d.report(member,
                  "object literal fields must be initialized")
              end
            end
          end
        end
      end
    end

  fun _gencap_outside_constraint(
    d: _Diags,
    nominal: USize,
    in_constraint: _ConstraintTracker)
  =>
    let tree = d.tree
    if in_constraint(nominal) then
      return
    end
    try
      for child in tree.children(nominal)? do
        match tree.kind(child)?
        | TkCapRead | TkCapSend | TkCapShare | TkCapAlias | TkCapAny =>
          d.report(child,
            "a capability set can only appear in a type constraint")
        end
      end
    end

  fun _consume(
    d: _Diags,
    consume_el: USize)
  =>
    let tree = d.tree
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
              d.report(_anchor(tree, child),
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
                  d.report(_anchor(tree, child),
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
          d.report(child,
            "Consume expressions must specify an identifier or field")
          return
        end
      end
    end

  fun _cast(
    d: _Diags,
    as_el: USize)
  =>
    let tree = d.tree
    try
      for child in tree.children(as_el)? do
        match tree.kind(child)?
        | TkWhitespace | TkLineComment | TkNestedComment => None
        | TkInt | TkFloat =>
          d.report_with_info(child,
            "Cannot cast uninferred numeric literal",
            "To give a numeric literal a specific type, use the " +
              "constructor of that numeric type")
          return
        else
          return
        end
      end
    end

  fun _annotations(
    d: _Diags,
    anns: USize,
    stack: Array[(USize, SyntaxKind)] box)
  =>
    let tree = d.tree
    try
      for child in tree.children(anns)? do
        if tree.kind(child)? is TkId then
          let name = d.text(child)
          if name.compare_sub("ponyint", 7) is Equal then
            d.report(child,
              "annotations starting with 'ponyint' are reserved for " +
                "internal use")
          else
            _annotation_location(d, child, name, stack)
          end
        end
      end
    end

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

