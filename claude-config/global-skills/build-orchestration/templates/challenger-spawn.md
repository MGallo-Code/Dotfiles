# Challenger spawn prompt (Orchestrator fills the <...>)

Spawn the `challenger` agent (Agent tool, subagent_type `challenger`). Never fork it.

---
Candidate <SLICE> r<N> (<plan|implementation>). Your inbox: <abs>/<project>-challenger/analysis_outputs/reviewer-evidence/inbox/<ID>/ (ASSIGNMENT.md, LAUNCH.md, candidate-manifest.json sha256 <hash>, execution-copy/). Work only from there.
Pass 1 only for now: the builder materials are withheld until you report PASS1_COMPLETE.
Findings that count: correctness, the brief, and handoff section 5 preferences (copied into ASSIGNMENT.md).
<If a high-stakes plan review: "Derive first: write your own answers to the plan's numbered questions before reading plan.md, then compare.">
---

Record the returned agent id in RESUME.md. After PASS1_COMPLETE: copy the builder materials into the inbox, then SendMessage the same instance: "Pass 2: builder materials are in <abs>/.../builder-materials/ (sha256 <hash>)."
