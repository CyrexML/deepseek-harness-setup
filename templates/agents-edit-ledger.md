## `edit` needs the file opened first

<!-- dsh-local: edit-ledger-rule -->
The stand refuses an `edit`, or an overwrite of an existing file, unless it has
seen that file this session. A `read` counts, and so does your own `write`.
`grep`, `sed -n` and `cat` in bash do not: they find a line, they do not open
the file. So: locate with `grep`, open the region with `read`, then edit.

The same stamp goes stale the moment the file changes by another route. A
`sed -i`, a shell redirect or a generated file followed by `edit` on that file
is always one refused call. Pick one hand per file per step: either the shell
rewrites it, or `edit` does.
