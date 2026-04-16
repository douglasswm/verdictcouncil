## Branching Strategy (Trunk-Based)

The orchestration root is **trunk-based on `main`** — there is no `release/*`, no `development`, no gitflow. Commit submodule bumps and root-level docs/config straight to `main` (PRs are optional, used only when a change benefits from review).

### Why trunk on the root

The root contains only:
- Submodule pointers (`VerdictCouncil_Backend`, `VerdictCouncil_Frontend`)
- Root-level docs (`AGENTS.md`, `CLAUDE.md`, `README.md`)
- Dev tooling (`dev.sh`, etc.)

There is no application code, no CI gating, no staging environment to validate against. A multi-stage gitflow adds ceremony with no payoff.

### Rules

- Commit directly to `main` for submodule bumps, doc edits, and tooling changes.
- Open a PR only when the change is non-trivial and benefits from a second look.
- **The submodules still follow gitflow** — see `VerdictCouncil_Backend/CLAUDE.md` and `VerdictCouncil_Frontend/CLAUDE.md`. Any code work happens inside a submodule on its own `feat/*` → `development` → `release/*` → `main` track. The root only ever records the resulting submodule SHA.

### Submodule bump workflow

After a submodule's `development` (or `main`) advances:

```bash
cd /path/to/orchestration-root
git add <SubmoduleDir>
git commit -m "chore: bump <submodule> to <short-sha> (<summary>)"
git push origin main
```

Use `git diff --cached --submodule=log` before committing to see the submodule's commit list in the diff.

---

### 1. Plan Mode Default

- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately – don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

### 2. Subagent Strategy

- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution

### 3. Self-Improvement Loop

- After ANY correction from the user: update `tasks/lessons.md` with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review lessons at session start for relevant project

### 4. Verification Before Done

- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

### 5. Demand Elegance (Balanced)

- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes – don't over-engineer
- Challenge your own work before presenting it

### 6. Autonomous Bug Fixing

- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests – then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how

---

## Task Management

1. **Plan First**: Write plan to `tasks/todo.md` with checkable items
2. **Verify Plan**: Check in before starting implementation
3. **Track Progress**: Mark items complete as you go
4. **Explain Changes**: High-level summary at each step
5. **Document Results**: Add review section to `tasks/todo.md`
6. **Capture Lessons**: Update `tasks/lessons.md` after corrections

---

## Commit Rules

When tasked to create a commit, follow this process:

1. **Understand what changed**: Review conversation history, run `git status` and `git diff`
2. **Plan commits**: Identify which files belong together, draft clear commit messages using imperative mood, focus on *why* not *what*
3. **Present plan to user**: List files and commit messages, ask "I plan to create [N] commit(s). Shall I proceed?"
4. **Execute on confirmation**: Use `git add` with specific files (never `-A` or `.`), create commits, show result with `git log --oneline`

### Commit Message Format

- Use imperative mood ("Add feature" not "Added feature")
- Keep subject line under 72 characters
- Add body for non-trivial changes explaining the *why*

### Strict Prohibitions

- **NEVER add co-author lines** (`Co-Authored-By`, `Co-authored-by`, etc.)
- **NEVER add Claude/AI attribution** of any kind
- **NEVER include "Generated with Claude" or similar messages**
- **NEVER use `--co-author` flags**
- Commits must read as if the user wrote them — no AI fingerprints

### Safety

- Never commit secrets (`.env`, credentials, API keys)
- Never use `git add -A` or `git add .` — always add specific files
- Verify staged changes with `git diff --cached` before committing

---

## Core Principles

- **Simplicity First**: Make every change as simple as possible. Impact minimal code.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.
- **Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.

---

## gstack

Use `/browse` from gstack for **all web browsing** — never use `mcp__claude-in-chrome__*` tools directly.

Available skills: `/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/design-consultation`, `/design-shotgun`, `/design-html`, `/review`, `/ship`, `/land-and-deploy`, `/canary`, `/benchmark`, `/browse`, `/connect-chrome`, `/qa`, `/qa-only`, `/design-review`, `/setup-browser-cookies`, `/setup-deploy`, `/retro`, `/investigate`, `/document-release`, `/codex`, `/cso`, `/autoplan`, `/plan-devex-review`, `/devex-review`, `/careful`, `/freeze`, `/guard`, `/unfreeze`, `/gstack-upgrade`, `/learn`

If gstack skills aren't working, run `cd ~/.claude/skills/gstack && ./setup` to build the binary and register skills.


