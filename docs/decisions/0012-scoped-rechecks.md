# 0012 - Orchestrated revisions re-check what they touched; the full chain runs once

Status: accepted 2026-10-21 (Michael: "You can go ahead and run with this", after the
measurements below; applies to assignments written from that date).

## Context

Michael noticed WizBot and WizWiki "test runs" taking about 4 hours. Both projects'
Orchestrators reported where the time goes (2026-10-21):

- WizBot: the full revert/plant set took 57 min to 2.4 h; one gate's revert test alone ran
  97 min (302 plants, each re-parsing the source). Frame replay 10 to 20 min. The Challenger
  re-runs the same gates and replays on its own copy, 35 to 50 min per pass, two passes.
  Slices need 2 to 3 rounds, and every round repeats all of it.
- WizWiki: the Builder's chain is 95 to 160 min per revision (44 to 69 plants, each
  rebuilding the data from about 1,600 cached pages, plus Edge journeys); the Challenger
  adds 40 to 70 min per round. One slice has had 8 candidates.
- Neither is slow product code, the network, or waiting on Michael. Nothing mechanical
  forces the full re-run. It is policy: assignments ask for the whole chain GREEN on every
  candidate, the Builder re-runs everything after any fix, and each fresh Challenger
  re-derives every gate result rather than trusting the Builder's log.

The handoff itself asks for less: the Builder "runs gates" per candidate, and only the
milestone freeze slice must "re-run the whole acceptance table on the final build". A gate
and its plants are deterministic functions of the files they read, so re-running them on
unchanged inputs proves nothing new.

## Decision

Rules of record: skill `build-orchestration`, item 7. In short:

- **Only static gates and their plants are scoped.** They are deterministic functions of the
  files they read, and they are where the hours go. Replays, browser journeys, socket watches
  and Challenger pass 1 depend on the whole runnable tree and the environment, so they run on
  every candidate as before.
- **Per revision, the Orchestrator lists the gates to run** from a per-project
  gate-to-files map (script, imports, files and data read). A gate with no row always runs.
  An added, removed or renamed file, a map edit, or a dependency or interpreter change means
  the full chain.
- **The full chain runs before review of the candidate the Builder proposes as final**, and
  the Challenger reviewing that candidate re-runs it itself, so every accepted slice has an
  independent full run. Earlier candidates' Challengers re-run the listed gates and prove the
  rest unchanged by hash. The milestone freeze still re-runs the whole acceptance table, as the
  handoff says.
- **Safety valve**: a failure the full chain finds that the scoped gates missed is a
  `scoped_miss`. Fix the map row before acceptance; the project then runs the full chain on
  every candidate until a scoped slice passes its final full chain with zero misses.
- **In-flight work is untouched**: a slice whose first assignment predates 2026-10-21 keeps its
  acceptance rules through all its revisions.

A fresh-context adversarial review of the first draft found that it let journeys skip, could
not trip its own valve, left "final candidate" undefined and keyed in-flight safety on each
revision's assignment; all four are fixed above.

## Consequences

- Expected: a non-final revision costs minutes of checks instead of hours, and a slice
  pays the full chain twice (Builder and Challenger, on the final candidate). The custody guarantee (frozen bytes proven by hash) is unchanged.
- Cost: each project must write and maintain the gate-to-files map. A wrong row can hide a
  regression until the final candidate's full chain, which then catches it (later than today,
  never accepted). Rare flakes surface less often, since the full chain runs twice per slice
  instead of on every revision.
- This is the one ceremony change the skill's metrics rule allows at a time; `scoped_misses`
  and the review-round count decide whether it stays.
- Project-side work stays with each project's Orchestrator: the map, and making plant
  suites parse once per plant set (WizBot's ordered-spell gate).
