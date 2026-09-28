## A path is copied, never retyped

<!-- dsh-local: path-copy-rule -->
Take every path from the output that produced it: the line `grep -n` printed,
the `<path>` a read returned, the path the task gave you. Never copy one out of
your own failed call — a call that failed carries a path that does not exist,
and repeating it repeats the failure.

After one "not found" that path is dead. Find the real one (`ls` its parent, or
`grep -rl <filename>`), take it from that output, and go on from there.
