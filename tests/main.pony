use "pony_test"
use "../upstream/tools/lib/ponylang/pony_syntax"
use "../upstream/tools/lib/ponylang/pony_query"
use "../upstream/tools/lib/ponylang/pony_bind"

actor \nodoc\ Main is TestList
  new create(env: Env) =>
    PonyTest(env, this)

  new make() =>
    None

  fun tag tests(test: PonyTest) =>
    """
    Run all pony_syntax test suites.
    """
    _TokenKindTests.tests(test)
    _LexerTests.tests(test)
    _TreeTests.tests(test)
    _GrammarTests.tests(test)
    _LineIndexTests.tests(test)
    _AnalysisTests.tests(test)
    _QueryTests.tests(test)
    _BindTests.tests(test)
    _ScopeTests.tests(test)
