# Local word learning implementation plan

> For agentic workers: execute via superpowers:subagent-driven-development.

**Goal:** Learn per-machine RU/EN word preferences after two independent confirmed user choices and remove a rule after an opposite choice.
**Architecture:** Separate bounded adaptive policy/store, typed correction provenance, composed personal lexicon overlay. Baseline editor transport stays unchanged.
**Tech Stack:** Existing Swift6/Foundation/AppKit and C# net462/net10/WinForms/BCL; no new packages/services.
**Spec:** ../local-learning.md

## Global constraints

Both platforms; threshold2; 2000 records/512KiB; words1–64UTF16. No typed-text/phrase/context/clipboard/PID/app history, cloud or passive approval. Explicit personal preferences outrank adaptive. Owner confirmed default-ON with clear first-launch explanation; preserve explicit off and migrate missing key to ON. Enable owner Mac only after verified update. Synthetic test data only.

## Review focus

- Repeated undo/redo accidentally promotes a rule: stable occurrence/provenance and withdrawal tests.
- Early prediction outruns a learned keep-word: preferred-word prefix hold and boundary tests.
- Corrupt/disk-full store poisons baseline or loses manual dictionary: separate store, atomic rollback/read-only tests.
- Wrong keyboard indicator/mapping punctuation/ё silently drops words: script/canonical mapping tests.
- Disabled learning continues saving/applying or new update clears rules: live toggle/restart/reset/provenance integration tests.

## Task1 · macOS adaptive feature

Owner macOS writer, exclusively macos/. Add small AdaptiveLearning domain/store/settings view files; integrate confirmed manual combined-Shift and confirmed automatic undo, live personal lexicon/preferred prefix protection; settings toggle/list/delete/reset. Reuse PersonalWordStore I/O security pattern.
- [x] First pin failing synthetic cases from Spec acceptance, including no feedback loops and opposite/forget.
- [x] Implement policy, bounded atomic store and event provenance; do not count generic automatic apply/recovery.
- [x] Wire live UI/lexicon and test off/priority/corrupt/restart; Mac corrections with current-layout mismatch included.
- [x] Targeted Swift tests then full existing swift test/build once after coherent changes.
- [x] Return exact changed paths, checks and unverified runtime; no Git/GUI/install/external publication.

## Task2 · Windows adaptive feature

Owner Windows writer, exclusively windows/. Add AdaptiveLearning Core class/tests and separate Storage class; correction receipt origin/occurrence/action; live personal overlay/prefix protection; settings toggle/list/delete/reset. Keep 90ms writer and no SendInput policy.
- [x] Pin same synthetic semantic cases, source/undo/redo provenance and profile I/O failure cases.
- [x] Implement separate policy/store/settings without changing personal schema1.
- [x] Wire confirmed automatic-undo/manual-only signals and lookup; no generic applied-event inference.
- [x] net10 Core tests + net462 app/runtime-fixture cross-build; own Windows fixture paths only.
- [x] Return paths/checks/risks; no Git/install/CI/publication.

## Task3 · integration, review and delivery

Owner parent, common docs/root rules only. Public common contract overrides platform guesses. If implementation ambiguity remains, record ruling; no unannounced feature drop.
- [x] Check policy parity and scoped task-review after each platform; independent code/privacy-risk/secrets/skeptic lenses on Luna per project, max2 rounds.
- [x] Update architecture/roadmap/release notes and safe version pins.
- [x] Local targeted checks once, scanner exit0 gates all outbound commits/pushes.
- [x] One final manual workflow per platform, additional runs only after concrete failing gate + fix.
- [x] Release signatures/public artifact+feed readback; normal Mac update preserves originals/settings, never force-kill. Physical HID/app matrix remains separate.

## Rulings

- Separate adaptive file prevents automated feedback from rewriting manually curated personal words.
- No chronological journal: word-pair record/counter provides learning while minimizing retained input.
- Task1/Task2 share only the Spec; no shared source files and no simultaneous writers on same file.
- The existing project critic-review max2 rounds overrides SDD's general larger repair-loop allowance.

## Delivery

Source58a529f0dcff6aa3cde5439f028d257ee023420a; MacCI41630893348PASS502/Python35/gold495, WindowsCI41630906057PASS626/gold495/runtime44. Both releases/feeds published and publichash/signature readbacks passed. MacnormalSparkleupdate25 installed; priornon-updaterprefs/manualdictionarypreserved, learningON/disclosureshown. Physicallearninguserwords notrun; notanuncheckedimplementationstep, separateacceptance limit.
