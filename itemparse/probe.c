// Probe: can each top-level item of a Pony file be parsed as its own module,
// newline-padded to its real start line, with correct positions?
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pass/pass.h"
#include "ast/ast.h"
#include "ast/source.h"
#include "ast/parser.h"
#include "ast/error.h"
#include "ast/stringtab.h"
#include "ast/token.h"
#include "ast/lexer.h"

static const char* KEYWORDS[] = {
  "use ", "class ", "actor ", "primitive ", "trait ", "interface ",
  "struct ", "type ", "class\t", "actor\t", NULL
};

static int starts_item(const char* line)
{
  for(int i = 0; KEYWORDS[i] != NULL; i++)
    if(strncmp(line, KEYWORDS[i], strlen(KEYWORDS[i])) == 0)
      return 1;
  // bare "class" etc at EOL
  return 0;
}

// Print every top-level entity in a module AST: kind, name, line, pos.
static void dump_module(ast_t* module, const char* tag)
{
  for(ast_t* p = ast_child(module); p != NULL; p = ast_sibling(p))
  {
    const char* name = "-";
    ast_t* id = ast_child(p);
    while(id != NULL && ast_id(id) != TK_ID)
      id = ast_sibling(id);
    if(id != NULL)
      name = ast_name(id);
    printf("%s %-12s %-24s line=%zu pos=%zu\n",
      tag, lexer_print(ast_id(p)), name, ast_line(p), ast_pos(p));
  }
}

static char* read_file(const char* path, size_t* out_len)
{
  FILE* f = fopen(path, "rb");
  if(f == NULL) { perror("open"); exit(1); }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char* buf = (char*)malloc(n + 1);
  size_t rd = fread(buf, 1, n, f);
  buf[rd] = '\0';
  fclose(f);
  *out_len = rd;
  return buf;
}

static int parse_one(pass_opt_t* opt, const char* text, const char* tag,
  int quiet)
{
  ast_t* package = ast_blank(TK_PACKAGE);
  ast_scope(package);
  source_t* src = source_open_string(text);
  size_t before = errors_get_count(opt->check.errors);
  bool ok = pass_parse(package, src, opt->check.errors, opt->strtab,
    false, false);
  size_t after = errors_get_count(opt->check.errors);

  if(ok)
  {
    ast_t* module = ast_child(package);
    if(module != NULL && !quiet)
      dump_module(module, tag);
  }
  else if(!quiet)
  {
    printf("%s PARSE FAILED (%zu new errors)\n", tag, after - before);
  }
  ast_free(package);
  return ok ? 1 : 0;
}

int main(int argc, char** argv)
{
  if(argc < 2) { printf("usage: probe <file.pony> [--break N]\n"); return 1; }
  int break_item = -1;
  for(int i = 2; i < argc - 1; i++)
    if(strcmp(argv[i], "--break") == 0) break_item = atoi(argv[i + 1]);

  size_t len;
  char* text = read_file(argv[1], &len);

  pass_opt_t opt;
  pass_opt_init(&opt);
  errors_set_immediate(opt.check.errors, false);

  int mode = 0; // 0 both, 1 whole only, 2 items only
  for(int i = 2; i < argc; i++) {
    if(strcmp(argv[i], "--whole-only") == 0) mode = 1;
    if(strcmp(argv[i], "--items-only") == 0) mode = 2;
  }
  int quiet = (mode != 0);
  if(mode != 2) {
    if(!quiet) printf("=== whole-file parse ===\n");
    parse_one(&opt, text, "WHOLE", quiet);
  }
  if(mode == 1) { pass_opt_done(&opt); return 0; }

  // Split into top-level items by scanning for a keyword at column 0.
  // Record the 0-based start line of each.
  if(!quiet) printf("\n=== per-item parse (newline padded to start line) ===\n");
  int n_items = 0, n_ok = 0;
  size_t line_no = 0;
  char* cursor = text;
  char* item_start = NULL;
  size_t item_line = 0;

  // collect line starts
  size_t cap = 4096, count = 0;
  char** starts = (char**)malloc(cap * sizeof(char*));
  size_t* lines = (size_t*)malloc(cap * sizeof(size_t));
  starts[count] = text; lines[count] = 0; count++;
  for(char* p = text; *p != '\0'; p++)
    if(*p == '\n' && *(p+1) != '\0')
    {
      if(count == cap) { cap *= 2;
        starts = (char**)realloc(starts, cap * sizeof(char*));
        lines = (size_t*)realloc(lines, cap * sizeof(size_t)); }
      starts[count] = p + 1; lines[count] = count; count++;
    }

  for(size_t i = 0; i < count; i++)
  {
    if(!starts_item(starts[i])) continue;
    // item runs from here to the next item start (or EOF)
    char* end = text + len;
    for(size_t j = i + 1; j < count; j++)
      if(starts_item(starts[j])) { end = starts[j]; break; }

    size_t body_len = end - starts[i];
    size_t pad = lines[i];
    char* buf = (char*)malloc(pad + body_len + 64);
    memset(buf, '\n', pad);
    memcpy(buf + pad, starts[i], body_len);
    buf[pad + body_len] = '\0';

    char tag[64];
    n_items++;
    if(break_item == n_items)
    {
      // corrupt it: append an unmatched open paren
      strcat(buf, "\n  fun broken(: \n");
      snprintf(tag, sizeof(tag), "ITEM%-2d(broken)", n_items);
    }
    else
      snprintf(tag, sizeof(tag), "ITEM%-2d", n_items);

    n_ok += parse_one(&opt, buf, tag, quiet);
    free(buf);
  }

  if(!quiet) printf("\n%d items, %d parsed\n", n_items, n_ok);
  pass_opt_done(&opt);
  return 0;
}
