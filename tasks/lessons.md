# Lessons Learned

- For review-only or planning-artifact tasks in this repo, update `tasks/todo.md` with the completed work and review summary before final response, even when no application code changes.
- When publishing branches and PRs, do not assume the PR body was saved just because the branch push and PR creation succeeded. Always verify the live PR metadata and, if the body is empty or incomplete, update it before closing the task.
- When committing from a mixed worktree, explicitly identify which changes came from this session before staging. Use file-specific staging or hunk staging so unrelated user changes do not get swept into the commit.
