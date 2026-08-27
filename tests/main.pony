use "pony_test"
use "../pony_syntax"

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
