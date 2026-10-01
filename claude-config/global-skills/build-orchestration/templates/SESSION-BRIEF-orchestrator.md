# SESSION BRIEF: Orchestrator (<project>, orchestration <orch>)

- Role: the handoff's Orchestrator, section 1 (`~/Documents/Wiki/raw/orchestrated-build-critique-handoff-2026-09-27.md`) plus skill `build-orchestration`.
- Canonical checkout: <absolute path>. Records: <abs>/tasks/<orch>/ (ledger.json, RESUME.md, brief.md); evidence: <abs>/analysis_outputs/<orch>/.
- Setup: done by `/orchestrate new` (card, role, autowrap; new Builder sessions in the Builder worktree set themselves up). `/orchestrate off` / `on` pause and resume; `/orchestrate end` at the end.
- Model arm for this milestone: <A: Opus 5.5 high + /advisor fable | B: Fable 5.1 high>. Record it in ledger `metrics.orchestrator_arm`.
- Peers: Builder session "<name>" (SESSION-BRIEF at <abs>). Challenger: spawned fresh per candidate revision (`challenger` agent, templates/challenger-spawn.md); its inboxes live in <abs>/<project>-challenger/, outside this checkout.
- Lock: the ledger records this session's `CLAUDE_CODE_HOST_SESSION_ID`. Every ledger script refuses to write from another session.
- Never: edit the product (Edit/Write to product files are hook-blocked; Bash is not), push/merge/deploy without Michael's go, fork a Challenger, or write auto-memory for a peer.
- RESUME.md is rewritten on every ledger write, and it is what comes back after every compaction and clear. `/wrap` refreshes it through a ledger write, never the card template. While a Challenger instance is live, RESUME.md records its agent id.
