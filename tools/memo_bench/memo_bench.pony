"""
Which memo store the query engine should use, measured rather than reasoned
about.

`DESIGN.md` question 2 names three candidates and says no Rust number decides
between them, because `FINDINGS.md` priced reads and never priced publish. In
Pony publish is what decides it: a flat `val` map cannot be extended, so a new
version means rebuilding the whole thing.

`make bench` runs this and `tools/actor_latency`.
"""
