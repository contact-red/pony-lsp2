# Building and testing, here rather than in ponyc's tree.
#
# PONYC_ROOT is a ponyc checkout, needed for two things: its standard
# library, which the language server locates relative to its own executable,
# and libponyc-standalone, which the pony_compiler bridge links against.

PONYC_ROOT ?= $(HOME)/projects/ponylang/ponyc
PONYC_LIB  ?= $(PONYC_ROOT)/build/release
BRIDGE     := upstream/tools/lib/ponylang/pony_compiler
PATHS      := --path $(BRIDGE) --path $(PONYC_LIB)

.PHONY: all test syntax-test lsp lsp-test corpus clean

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

# Whole-corpus checks: the lexer against ponyc's, every file reprinting from
# its tree, and the facts projecting without a gap. See tools/agreement.
corpus: packages
	ponyc -b dump -o tools/agreement tools/agreement/dump_src
	gcc -O2 -o tools/agreement/ponyc_dump tools/agreement/ponyc_dump.c \
	  -Itools/agreement \
	  -I$(PONYC_ROOT)/src/libponyc -I$(PONYC_ROOT)/src \
	  -I$(PONYC_ROOT)/src/common \
	  $(PONYC_LIB)/libponyc-standalone.a $(PONYC_LIB)/libponyrt-pic.a \
	  -lstdc++ -lm -lz -lpthread -ldl -latomic
	tools/agreement/check.py $(PONYC_ROOT)/packages/*/*.pony \
	  $(PONYC_ROOT)/packages/*/*/*.pony
	tools/agreement/dump --reprint $(PONYC_ROOT)/packages/*/*.pony \
	  $(PONYC_ROOT)/packages/*/*/*.pony
	tools/agreement/dump --facts $(PONYC_ROOT)/packages/*/*.pony \
	  $(PONYC_ROOT)/packages/*/*/*.pony

clean:
	rm -rf build
	rm -f tools/agreement/dump tools/agreement/ponyc_dump
	rm -f tools/agreement/*.o
