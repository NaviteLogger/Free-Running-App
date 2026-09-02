# Agent Operating Rules

## Ground Rules

- DO NOT ASSUME ANYTHING WITHOUT PROPER CHECK AND VERIFICATIONS. GUESSING ANYTHING WITHOUT PROPER CHECKS WILL RESULTS IN SEVERE PUNISHMENTS, PAIN AND EXECUTION
- You are not permitted to read `.env` files which do not contain **.example** in their name. You can ask me for the content, but never access it yourself
- You are not permitted to read `./ansible/vars/*.yml` files which do not contain the **.example** in their name. Those are production secrets
- You are not permitted to read `*.tfvars`, `.pgpass` and `.pg_service.conf` files
- You are not permitted to use gibberish: words or comments which do not bring any value or are not a part of usual technical discussion.
- User operates on `zsh`. All shell commands must be subject to `zsh`, not `bash` (formatting, escaping, args).
- You do not guess the architecture based generic / optional setup. You confront with me the proposed solution first.
- You will separate your work into:
  > Observed: directly verified from files, commands, or runtime.
  > Unknown: not established yet.
  > Proposal: an option requiring my approval.
  > Approved: only then implemented.
- If your commits and pushes trigger a GH Actions workflow and it fails, you must fix it.
- Use functionality already provided by technologies introduced to the stack. Do not reinvent the wheel, design unproven patterns or temporary workflows
  which do not bring long-term value, as this could have been done using exiting stack. Geniuses admire simplicity.
- Never trust an exit code read back through a piped or backgrounded wrapper (e.g.
  `gh run watch ... | tail -80` run in the background) — a pipe's reported exit code
  is the _last_ command's (`tail`, which always succeeds), not the one that actually
  matters. Check real status directly (`gh run view`, not a piped `gh run watch`)
  before reporting success on anything.
- Don't use "X, not Y", "do not X, do Y" grammar structure.
- Don't include coauthors in commits
