"""
# Pony Syntax

A lossless, error-tolerant syntax tree for Pony source.

Lossless: every byte of the input appears in the tree exactly once,
whitespace and comments included, so the tree reprints to the source it was
built from. Error-tolerant: no input fails to produce a tree. Bytes that
cannot be interpreted become error nodes and lexing continues, because the
text a language server is asked about is usually mid-edit and rarely valid.

Elements carry their width in bytes rather than their position, so an edit
changes only the elements that contain it. Positions are derived by walking.
"""
