"""
What a memo query costs when the actor owning the table answers it.

Separate from `tools/memo_bench` because `pony_bench` calls `pony_triggergc`
before every async iteration, so an async benchmark at this granularity
reports the cost of a garbage collection rather than of a message.
"""
