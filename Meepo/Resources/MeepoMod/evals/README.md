# Evals of the mod's skills

`claude plugin eval` cases for /meepo:review, /meepo:sync and /meepo:spec. Each case scaffolds a small git repo
(`fixture.sh`) and grades what the skill does there; `review-builtin` is Claude Code's own /code-review on the
same bug, to compare against.

```sh
cd Meepo/Resources/MeepoMod
claude plugin eval . --ablation none --scaffold --trust-plugin --allow-tools Bash Edit Write \
  --judge-model sonnet --runs 3 --output-dir "$TMPDIR/meepo-evals"
```

`--ablation none`: the skills are `disable-model-invocation`, Claude never picks them itself, so a no-plugin arm
would only measure a prompt nobody typed. The default judge (Haiku) failed right answers on wording ("fixed"
rather than "reported"); Sonnet doesn't.
