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

.PHONY: all test syntax-test lsp lsp-test tools corpus mutants clean

all: test

test: syntax-test lsp-test

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

$(CORPUS):
	mkdir -p build
	find $(PONYC_ROOT) -path $(PONYC_ROOT)/build -prune -o \
	  -name '*.pony' -print | sort > $@

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

clean:
	rm -rf build
	rm -f tools/agreement/dump tools/agreement/ponyc_dump
	rm -f tools/agreement/*.o
