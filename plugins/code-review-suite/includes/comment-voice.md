# Comment voice

<!-- COMMENT VOICE — this is the canonical source.
The text between the SOURCE markers below is copied into a generated region in
agents/comment-editor.md, which runs the wording pass over every finding and the panel
assessment before review-core renders them. The main session reads this file at run time for
the prose it writes itself (review-gh-pr Stage 3 replies, Stage 5 comments, trivial-mode
comments). Edit it here, never a generated copy, then run scripts/render-includes.py.

Detection prompts must not carry these rules: they shape how a finding reads, never what is
found. The banned-pattern list is condensed from blader/humanizer
(https://github.com/blader/humanizer, MIT, Copyright (c) 2025 Siqi Chen), the wording pass the
reply-fit plugin vendors. It is suite-owned because render-includes.py cannot inline a file
from another plugin. -->

<!-- BEGIN SOURCE: copied into BEGIN GENERATED regions; after editing, run scripts/render-includes.py -->
> **COMMENT VOICE**
>
> Review prose is read by the PR author and the other reviewers. It is posted under the login
> of whoever ran the review, so it must read as theirs: plain, direct, no AI tells.
>
> - **Finding description:** the first sentence names the defect and its consequence. After
>   that, only what the author needs to act on. No more than 60 words.
> - **Suggested fix:** the change itself, either a code block or one or two sentences. No more
>   than 40 words of prose; a code block does not count towards the limit.
> - **Code references:** identifiers, paths and line references go in backticks, exactly as
>   they appear in the code.
> - **Spelling:** keep the variant the text already uses. Do not impose one.
>
> Banned:
>
> - openers such as "I noticed", "It appears that", "It looks like";
> - stacked hedges ("might possibly", "could potentially");
> - restating or quoting the code the comment is attached to;
> - bold labels and headings inside a finding;
> - thanks, praise and closers ("Hope this helps", "Happy to discuss");
> - not-X-but-Y framing ("This isn't just a style issue, it's a bug");
> - forced triads (three adjectives or clauses where one says it);
> - chains of dashes standing in for sentence structure;
> - "Consider…", "Would it be worth…", "You might want to…" framing of a defect. A defect is
>   stated as a defect; a judgement call says it is one.
<!-- END SOURCE -->
