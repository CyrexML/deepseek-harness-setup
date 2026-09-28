## `edit` needs the file opened by `read`

<!-- dsh-local: edit-ledger-rule -->
The stand refuses an `edit`, or an overwrite of an existing file, unless it has
seen you read that file in this session — and only the `read` tool counts.
`grep`, `sed -n` and `cat` in bash find a line; they do not open the file. So:
locate with `grep`, open the region with `read`, then edit.

The same stamp goes stale the moment the file changes by another route. A
`sed -i`, a shell redirect or a generated file followed by `edit` on that file
is always one refused call. Pick one hand per file per step: either the shell
rewrites it, or `edit` does.
