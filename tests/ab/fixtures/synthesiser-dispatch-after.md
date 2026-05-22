Some preamble text.

```
Agent({
    description: "Synthesise review findings",
    subagent_type: "code-review-suite:review-synthesiser",
    name: "review-synthesiser",
    mode: "auto",
    model: "opus",
    prompt: "Base branch: $BASE\nHead SHA: $HEAD_SHA\nReview mode: $REVIEW_MODE\n\nRest of prompt elided for fixture brevity."
})
```

Trailing prose — must not be touched by the mutation.
