// Dump the token kinds ponyc's own lexer produces, one per line, for
// comparison against pony_syntax's. Trivia are absent because ponyc's lexer
// discards them.
#include <stdio.h>
#include "pass/pass.h"
#include "ast/ast.h"
#include "ast/source.h"
#include "ast/lexer.h"
#include "ast/token.h"
#include "ast/error.h"
#include "tk_names.h"

int main(int argc, char** argv)
{
  pass_opt_t opt;
  pass_opt_init(&opt);

  for(int i = 1; i < argc; i++)
  {
    const char* err = NULL;
    source_t* src = source_open(argv[i], &err, opt.strtab);
    if(src == NULL) continue;
    printf("### %s\n", argv[i]);

    lexer_t* lex = lexer_open(src, opt.check.errors, opt.strtab, false);
    for(;;)
    {
      token_t* t = lexer_next(lex);
      token_id id = token_get_id(t);
      if(id == TK_EOF) { token_free(t); break; }
      printf("%s\n", tk_name(id));
      token_free(t);
    }
    lexer_close(lex);
    source_close(src);
  }

  pass_opt_done(&opt);
  return 0;
}
