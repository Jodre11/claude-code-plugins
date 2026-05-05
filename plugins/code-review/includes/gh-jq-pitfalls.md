### `gh --jq` pitfalls

`gh` uses `gojq` (Go jq), which does **not** support `!=`. The `!` is also mangled by zsh shell escaping. Use the `| not` idiom instead:
```jq
# WRONG — will error or silently break:
select(.state != "APPROVED")

# CORRECT:
select(.state == "APPROVED" | not)
```
Apply this to all `--jq` filters.
