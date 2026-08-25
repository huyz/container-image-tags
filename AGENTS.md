# Repository instructions

## Version control in Codex worktrees

- Before running `jj`, verify that `.jj` exists at the Git worktree root. If it does not, this is a Codex-managed Git worktree: use Git for status, diff, and history, and do not run bare `jj` commands. Jujutsu may otherwise walk up the filesystem and select an unrelated repository.
- Hand the chat off to Local before performing Jujutsu commit, describe, split, bookmark, rebase, or push operations. Alternatively, work from a directory created with `jj workspace add`, which has its own registered Jujutsu working copy.
