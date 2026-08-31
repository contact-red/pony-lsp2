# Building and testing, here rather than in ponyc's tree.
#
# PONYC_ROOT is a ponyc checkout, needed for two things: its standard
# library, which the language server locates relative to its own executable,
# and libponyc-standalone, which the pony_compiler bridge links against.

PONYC_ROOT ?= $(HOME)/projects/ponylang/ponyc
PONYC_LIB  ?= $(PONYC_ROOT)/build/release
LIBS       := upstream/tools/lib/ponylang
BRIDGE     := $(LIBS)/pony_compiler
PATHS      := --path $(BRIDGE) --path $(LIBS) --path $(PONYC_LIB)

.PHONY: all test syntax-test lsp lsp-test tools corpus mutants bind bench \
  types corpus-cases pass-reach memo-pays checker checker-probes \
  checker-stdlib checker-corpus column-oracle grammar-guard clean FORCE

all: test

test: grammar-guard syntax-test lsp-test checker-probes checker-stdlib

# Every grammar recursion cycle must contain a depth-guarded rule; a
# rule that opens an unguarded cycle fails here instead of crashing on
# a deep enough file.
grammar-guard:
	python3 tools/grammar_guard.py upstream/tools/lib/ponylang/pony_syntax

# The syntax tree, the parser and the analysis layer.
syntax-test:
	ponyc -b syntax-test -o build tests
	./build/syntax-test

# pony-lsp as vendored, with our changes on top.
lsp: packages
	ponyc $(PATHS) -b pony-lsp -o build upstream/tools/pony-lsp

lsp-test: packages
	ponyc $(PATHS) -b pony-lsp-test -o build upstream/tools/pony-lsp/test
	cd upstream/tools/pony-lsp/test && \
	  ../../../../build/pony-lsp-test --sequential

# The language server finds the standard library at ../packages relative to
# its own executable, which is the installed layout. The binaries are in
# build/, so this is what makes that resolve.
packages:
	ln -sfn $(PONYC_ROOT)/packages packages

# Every Pony file in the ponyc tree, not only the standard library: its own
# test fixtures are where the grammar's edge cases live. Two of them have a
# space in the path, so the list goes through a file rather than a glob.
CORPUS := build/corpus.txt

tools: packages
	ponyc -b dump -o tools/agreement tools/agreement/dump_src
	gcc -O2 -o tools/agreement/ponyc_dump tools/agreement/ponyc_dump.c \
	  -Itools/agreement \
	  -I$(PONYC_ROOT)/src/libponyc -I$(PONYC_ROOT)/src \
	  -I$(PONYC_ROOT)/src/common \
	  $(PONYC_LIB)/libponyc-standalone.a $(PONYC_LIB)/libponyrt-pic.a \
	  -lstdc++ -lm -lz -lpthread -ldl -latomic

# Rebuilt on every run rather than cached. Nothing about the list records
# which files the tree held when it was written, so a cached one silently
# drops a file added since -- and the walk costs far less than the checks
# that read it.
$(CORPUS): FORCE
	mkdir -p build
	find $(PONYC_ROOT) -path $(PONYC_ROOT)/build -prune -o \
	  -name '*.pony' -print | sort > $@

FORCE:

# Whole-corpus checks: the lexer against ponyc's, every file reprinting from
# its tree, and the facts projecting without a gap. See tools/agreement.
corpus: tools $(CORPUS)
	xargs -a $(CORPUS) -d '\n' tools/agreement/check.py
	xargs -a $(CORPUS) -d '\n' tools/agreement/dump --reprint
	xargs -a $(CORPUS) -d '\n' tools/agreement/dump --facts

# The same losslessness over sources that are not valid Pony, because a file
# being typed is not. Reports failures, not diagnostics: a mutant is meant
# to produce those.
mutants: tools $(CORPUS)
	rm -rf build/mutants
	xargs -a $(CORPUS) -d '\n' tools/agreement/mutate.py build/mutants
	tools/agreement/dump --reprint build/mutants/*.pony | \
	  grep -vE '^(DIAGNOSTICS|  )' 

# Every entity the standard library declares, resolved from its own file back
# to itself, and every `use` naming a package the workspace has.
bind:
	ponyc -b bind-check -o build tools/bind_check
	@./build/bind-check $(PONYC_ROOT)/packages \
	  $(shell find $(PONYC_ROOT)/packages -name '*.pony' | sort)

# The measurement question 2 of DESIGN.md says to take before committing to a
# memo store. `actor_latency` is separate because pony_bench triggers a GC
# before every async iteration and so cannot measure a message.
bench:
	ponyc -b memo-bench -o build tools/memo_bench
	ponyc -b actor-latency -o build tools/actor_latency
	./build/memo-bench
	./build/actor-latency

# What content-addressed type identity costs: the fourth measurement
# DESIGN.md question 2 listed and did not take. See SEMANTIC_DESIGN.md.
types:
	ponyc -b type-hash -o build tools/type_hash
	./build/type-hash

# ponyc's own unit tests as a corpus of accept/reject verdicts, and the
# per-case instrument recording what ponyc empirically does with each. See
# SEMANTIC_DESIGN.md's first-slice section and tools/corpus/README.md.
CORPUS_CASES ?= build/corpus_cases

corpus-cases:
	python3 tools/corpus/extract_corpus.py $(PONYC_ROOT) $(CORPUS_CASES)

pass-reach: corpus-cases
	python3 tools/corpus/pass_reach.py $(CORPUS_CASES)

# Whether memoizing a subtype decision pays for a batch checker, which is
# what FINDINGS.md's "The fork" says it does not. See tools/memo_pays.
memo-pays:
	ponyc -b memo-pays -o build tools/memo_pays
	./build/memo-pays

# The slice-0 checker: build it, run the corpus through it, and score the
# verdicts per case. See tools/checker and SEMANTIC_DESIGN.md.
checker:
	ponyc -b checker -o build tools/checker

checker-probes: checker
	tools/checker/probes/run.sh ./build/checker "$(PONYC_ROOT)/packages"

# Every package in ponyc's standard library must check clean: the gate the
# corpus cannot provide, because no corpus case uses a stdlib package
# beyond builtin.
checker-stdlib: checker
	@find "$(PONYC_ROOT)/packages" -name '*.pony' -not -name '.*' \
	  | xargs -d '\n' -n1 dirname | sort -u > build/stdlib_dirs.txt
	@test -s build/stdlib_dirs.txt || \
	  { echo "no packages under $(PONYC_ROOT)/packages"; exit 1; }
	@./build/checker --batch=build/stdlib_dirs.txt \
	  --path="$(PONYC_ROOT)/packages" > build/stdlib_verdicts.tsv
	@dirs=$$(wc -l < build/stdlib_dirs.txt); \
	got=$$(wc -l < build/stdlib_verdicts.tsv); \
	[ "$$dirs" -eq "$$got" ] || \
	  { echo "stdlib: $$got verdicts for $$dirs packages"; exit 1; }
	@fails=$$(awk -F'\t' '$$2 != "ok"' build/stdlib_verdicts.tsv | wc -l); \
	if [ "$$fails" -ne 0 ]; then \
	  awk -F'\t' '$$2 != "ok" { print "STDLIB FAIL: " $$1 }' \
	    build/stdlib_verdicts.tsv; \
	  awk -F'\t' '$$2 != "ok" { print $$1 }' build/stdlib_verdicts.tsv | \
	  while read -r d; do \
	    ./build/checker "$$d" --path="$(PONYC_ROOT)/packages" || true; \
	  done; \
	  echo "stdlib: $$fails packages failed"; exit 1; \
	else \
	  echo "stdlib: all packages clean"; \
	fi

# Positions, not just verdicts: wherever the checker and ponyc emit the
# same message on a reject case, the line and column must match.
column-oracle: checker
	@test -f $(CORPUS_CASES)/reach.tsv || \
	  { echo "no reach.tsv: run 'make pass-reach' once first"; exit 1; }
	python3 tools/corpus/column_oracle.py $(CORPUS_CASES) \
	  ./build/checker "$(PONYC_ROOT)/packages"

checker-corpus: checker corpus-cases
	@test -f $(CORPUS_CASES)/reach.tsv || \
	  { echo "no reach.tsv: run 'make pass-reach' once first"; exit 1; }
	cut -f5 $(CORPUS_CASES)/manifest.tsv > build/case_dirs.txt
	./build/checker --batch=build/case_dirs.txt \
	  --path=$(PONYC_ROOT)/packages > build/checker_verdicts.tsv
	python3 tools/corpus/corpus_report.py $(CORPUS_CASES)/manifest.tsv \
	  build/checker_verdicts.tsv --reach=$(CORPUS_CASES)/reach.tsv

clean:
	rm -rf build
	rm -f tools/agreement/dump tools/agreement/ponyc_dump
	rm -f tools/agreement/*.o
