# Agent Teams — Master Reference

Source: https://code.claude.com/docs/en/agent-teams
Status: experimental (Claude Code v2.1.32+)

Coordinate multiple Claude Code instances as a team. One **lead** session
spawns **teammates**, each with its own independent context window. Teammates
communicate directly with each other (unlike subagents, which only report to
the main agent).

---

## 1. Enable

Disabled by default. Set env var via `settings.json` or shell:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

Verify version: `claude --version` (must be ≥ 2.1.32).

---

## 2. When to use teams (vs subagents vs single session)

| Mode             | Best for                                                          |
| ---------------- | ----------------------------------------------------------------- |
| Single session   | Sequential tasks, same-file edits, work with many dependencies    |
| Subagents        | Focused tasks where only the result matters; lower token cost     |
| Agent teams      | Parallel work needing inter-agent discussion, debate, coordination |

| Property        | Subagents                                  | Agent teams                                  |
| --------------- | ------------------------------------------ | -------------------------------------------- |
| Context         | Own context; result returns to caller      | Own context; fully independent               |
| Communication   | Report to main agent only                  | Teammates message each other directly        |
| Coordination    | Main agent manages all                     | Shared task list; self-coordination          |
| Token cost      | Lower (results summarized back)            | Higher (each teammate = full Claude session) |

**Strong use cases for teams:**
- Research and review (multiple angles in parallel)
- New modules/features (each teammate owns separate piece)
- Debugging with competing hypotheses (parallel theory testing)
- Cross-layer changes (frontend / backend / tests by different owners)

**Weak use cases:** routine sequential work, anything with heavy file-overlap.

---

## 3. Architecture

| Component   | Role                                                                |
| ----------- | ------------------------------------------------------------------- |
| Team lead   | Main session that creates team, spawns teammates, coordinates       |
| Teammates   | Separate Claude Code instances, each working assigned tasks         |
| Task list   | Shared list; teammates claim + complete; supports dependencies      |
| Mailbox     | Messaging system between agents                                     |

**Storage (auto-managed, do not edit by hand):**
- Team config: `~/.claude/teams/{team-name}/config.json`
- Task list:  `~/.claude/tasks/{team-name}/`

`config.json` holds runtime state (session IDs, tmux pane IDs, members
array). Hand edits get overwritten on next state update. No project-level
equivalent — `.claude/teams/teams.json` in a project is NOT recognized.

Members array contains: name, agent ID, agent type. Teammates can read this
file to discover other team members.

---

## 4. Starting a team

Natural language. Lead decides team size unless you specify. Examples:

```text
I'm designing a CLI tool that helps developers track TODO comments across
their codebase. Create an agent team to explore this from different angles:
one teammate on UX, one on technical architecture, one playing devil's
advocate.
```

```text
Create a team with 4 teammates to refactor these modules in parallel.
Use Sonnet for each teammate.
```

Two start paths:
1. **You request** a team explicitly.
2. **Claude proposes** a team if task suits parallel work — you confirm.

---

## 5. Display modes

Set via `~/.claude/settings.json` `teammateMode`:

| Value         | Behavior                                                          |
| ------------- | ----------------------------------------------------------------- |
| `"auto"` (default) | Split panes if already inside tmux; else in-process          |
| `"in-process"`     | All teammates in main terminal; cycle with **Shift+Down**    |
| `"tmux"`           | Split panes; auto-detects tmux vs iTerm2                     |

Per-session override:
```bash
claude --teammate-mode in-process
```

**In-process keys:**
- `Shift+Down` — cycle through teammates (wraps back to lead)
- `Enter` — view a teammate's session
- `Esc` — interrupt teammate's current turn
- `Ctrl+T` — toggle task list

**Split-pane requires:** tmux OR iTerm2 + `it2` CLI (enable Python API in iTerm2 → Settings → General → Magic). NOT supported in VS Code integrated terminal, Windows Terminal, Ghostty. tmux works best on macOS; `tmux -CC` in iTerm2 is suggested entrypoint.

---

## 6. Controlling teammates

### Spawn with subagent definition

Reference any subagent type (project / user / plugin / CLI scope):

```text
Spawn a teammate using the security-reviewer agent type to audit the auth module.
```

Behavior:
- Honors definition's `tools` allowlist and `model`.
- Definition body **appended** to teammate system prompt (not replaced).
- Team coordination tools (`SendMessage`, task tools) ALWAYS available, even if `tools` restricts others.
- `skills` and `mcpServers` frontmatter fields are **NOT applied** when running as a teammate. Teammates load skills + MCP servers from project/user settings like a regular session.

### Plan-approval gate

```text
Spawn an architect teammate to refactor the authentication module.
Require plan approval before they make any changes.
```

Teammate stays in read-only plan mode → submits plan → lead approves/rejects with feedback → teammate revises → resubmits → on approval exits plan mode and implements.

Lead approves autonomously. Steer with criteria like "only approve plans that include test coverage."

### Direct messaging

Each teammate is a full independent session. Message any teammate by name. Names assigned by lead at spawn — tell lead what to call each teammate for predictable references.

To reach all: send one message per recipient.

### Tasks

Three states: pending, in_progress, completed. Tasks support dependencies — pending task with unresolved deps cannot be claimed.

Two assignment modes:
- **Lead assigns** explicitly.
- **Self-claim** — teammate picks next unassigned, unblocked task after finishing current.

File locking prevents race conditions on simultaneous claims.

### Shutdown / cleanup

```text
Ask the researcher teammate to shut down
```
Teammate can approve or reject with explanation.

```text
Clean up the team
```
Removes shared team resources. Fails if any teammate still running — shut down first. **Only the lead should run cleanup** — teammate cleanup may leave inconsistent state.

---

## 7. Permissions

- Teammates inherit lead's permission settings at spawn time.
- `--dangerously-skip-permissions` on lead → all teammates inherit it.
- Per-teammate mode CANNOT be set at spawn. Change individually after spawn.
- Pre-approve common operations in [permission settings](https://code.claude.com/docs/en/permissions) before spawning to reduce interruptions.

---

## 8. Hooks for quality gates

| Hook            | Trigger                              | Exit 2 effect                               |
| --------------- | ------------------------------------ | ------------------------------------------- |
| `TeammateIdle`  | Teammate about to go idle            | Send feedback, keep teammate working        |
| `TaskCreated`   | Task being created                   | Prevent creation, send feedback             |
| `TaskCompleted` | Task being marked complete           | Prevent completion, send feedback           |

---

## 9. Context + communication

Each teammate loads at spawn:
- `CLAUDE.md` (from working directory — works normally for teammates)
- MCP servers
- Skills
- Spawn prompt from lead

Lead's conversation history does **NOT** carry over — include task-specific context in spawn prompt.

Inter-agent mechanisms:
- **Automatic message delivery** — no polling needed
- **Idle notifications** — teammate stop auto-notifies lead
- **Shared task list** — visibility for all
- **Direct teammate messaging** — by name

---

## 10. Token usage

Scales linearly with active teammates. Each teammate = full context window. Worth it for research/review/feature work; overkill for routine tasks. See `/en/costs#agent-team-token-costs`.

---

## 11. Best practices

### Spawn prompt template
Include task-specific details, paths, constraints, expected output format:

```text
Spawn a security reviewer teammate with the prompt: "Review the
authentication module at src/auth/ for security vulnerabilities. Focus on
token handling, session management, and input validation. The app uses JWT
tokens stored in httpOnly cookies. Report any issues with severity ratings."
```

### Team size
- Start with **3–5 teammates**.
- Scale up only when work genuinely benefits from simultaneous work.
- 5–6 tasks per teammate keeps everyone productive without thrashing.
- 15 independent tasks → 3 teammates is good starting point.
- Three focused teammates often outperform five scattered ones.

### Task sizing
- Too small → coordination overhead exceeds benefit.
- Too large → teammates work too long without check-ins, wasted effort risk.
- Right → self-contained units producing clear deliverable (function, test file, review).

If lead under-decomposes: tell it to split work smaller.

### Lead behavior nudges
- "Wait for your teammates to complete their tasks before proceeding" — if lead starts implementing instead of delegating.
- Provide approval criteria in spawn prompt for plan-gated teammates.

### Avoid file conflicts
Two teammates editing same file → overwrites. Partition file ownership across teammates.

### Start with research/review
First-time team users: PR review, library research, bug investigation. Clear boundaries, no parallel writes.

### Monitor + steer
Don't run unattended too long. Check progress, redirect, synthesize.

---

## 12. Use case patterns

### Parallel code review (filter-by-domain)
```text
Create an agent team to review PR #142. Spawn three reviewers:
- One focused on security implications
- One checking performance impact
- One validating test coverage
Have them each review and report findings.
```
Each reviewer = different lens, no overlap. Lead synthesizes.

### Adversarial debugging (competing hypotheses)
```text
Users report the app exits after one message instead of staying connected.
Spawn 5 agent teammates to investigate different hypotheses. Have them talk
to each other to try to disprove each other's theories, like a scientific
debate. Update the findings doc with whatever consensus emerges.
```
Debate structure beats anchoring bias of single sequential investigation.

---

## 13. Troubleshooting

| Symptom                                  | Fix                                                                                  |
| ---------------------------------------- | ------------------------------------------------------------------------------------ |
| Teammates not appearing (in-process)     | Press `Shift+Down` to cycle — they may be running, just not visible                 |
| Task too small for team                  | Claude declines spawn; restate complexity                                            |
| Split panes requested but missing        | `which tmux`; for iTerm2, install `it2` CLI + enable Python API                      |
| Too many permission prompts              | Pre-approve common ops in permission settings before spawning                        |
| Teammate stops on error                  | View output (`Shift+Down` / pane click); send instructions OR spawn replacement      |
| Lead shuts down before work done         | Tell it to keep going; tell it to wait on teammates instead of doing work itself     |
| Orphaned tmux session                    | `tmux ls` then `tmux kill-session -t <name>`                                         |

---

## 14. Limitations (current, experimental)

- **No session resumption with in-process teammates** — `/resume` and `/rewind` do NOT restore them. Lead may message non-existent teammates → tell it to spawn new ones.
- **Task status can lag** — teammates sometimes don't mark tasks completed → blocks dependents. Update manually or nudge.
- **Shutdown can be slow** — teammate finishes current request/tool call first.
- **One team per session** — clean up current before starting new.
- **No nested teams** — teammates can't spawn their own teams.
- **Lead is fixed** — creator session is lead for lifetime. No promotion / transfer.
- **Permissions set at spawn** — no per-teammate mode at spawn time.
- **Split panes require tmux/iTerm2** — not supported in VS Code integrated terminal, Windows Terminal, Ghostty.

---

## 15. Quick decision matrix for THIS project

When designing future teams in `/Users/mayron/projects/mayron/cantio/`:

| Scenario                                          | Recommendation                                       |
| ------------------------------------------------- | ---------------------------------------------------- |
| Add new feature spanning Spotify + UI + lyrics    | Team of 3 — one per layer; partition files          |
| Audit perf / accessibility / security             | Team of 3 reviewers, distinct lenses                 |
| Investigate flaky bug with multiple suspects      | Team of 3–5 adversarial investigators (debate)       |
| Refactor single file                              | Single session                                       |
| Update one Swift type used in 5 files             | Subagent or single session                           |
| Research lyrics provider alternatives             | 2–3 research teammates, each one provider           |

Always: include exact file paths in spawn prompts, name teammates explicitly, partition file ownership, set plan-gating for risky work.
