> Archived; paths refer to the `flutter-final` tag.

You are implementing the full native SwiftUI replacement of the Budgie Flutter app.

## Where to work
- Worktree: /Users/khatruong/Documents/GitHub/flutter-budget/.claude/worktrees/swiftui-mvp-migration-71aa05
- Branch: claude/swiftui-mvp-migration-71aa05 (the existing SwiftUI MVP lives in native/).
- Work only in that worktree. Don't touch budget_app/ (the Flutter app is the reference, and ParityHarness runs it), amplify/ or src/.
- First step: commit the untracked plan docs, native/docs/FULL_APP_PLAN.md and native/docs/full-app/, in their own commit.

## Read first, in this order
1. AGENTS.md, then run `bd prime` and `bd ready`. Beads is the issue tracker; epic `budgie-uia` holds the migration. Read the memory `full-swift-app-decisions`.
2. native/docs/FULL_APP_PLAN.md: phases, decisions D1-D17, cross-cutting rules, security notes. This is the plan you execute.
3. native/docs/full-app/01..07-*.md: the per-area specs (exact copy strings, formulas, layout metrics, Core/AppModel API sketches, parity-test lists). Read the relevant spec fully before starting its workstream.
   - Where 01 describes a custom floating dock, D2 overrides it: use the native Liquid Glass TabView.
4. native/docs/MIGRATION_SPEC.md, UI_SPEC.md, PARITY_GAPS.md, and native/Budgie/App/AppModel.swift.

## Decisions already made (don't reopen)
- Look: replicate the Flutter redesign, including glow cards, Gabarito and Spline Sans Mono. Port Flutter's legacy-look screens to the redesign tokens.
- Shell: native TabView with Liquid Glass, 5 tabs: Home, Worth, Goals, Spend, Flow.
  - Settings is pushed from a gear in the Home header. Recurring is a row under Settings > DATA.
  - Minimum iOS stays 17; Liquid Glass appears on 26+.
- Icons: SF Symbols tinted with Flutter's colours and tile backgrounds.
- Voice: OpenAI, key embedded in the app.
  - The key comes from a gitignored native/Config/Secrets.xcconfig through Info.plist (plan section 6).
  - Commit only Secrets.example.xcconfig with a placeholder. Never create, request, read or print a real key; I'll supply it.
- For D4-D17, follow the plan's recommendations. If one turns out to be wrong in practice, ask me one focused question instead of guessing.

## Order of work
- Do the phases in plan order.
- File the work in beads first:
  - One bead per Phase 1 item (1A.1-1A.8, 1B.1-1B.5, 1C.1-1C.6) under budgie-uia.
  - One bead per Phase 2-5 workstream, with --deps matching the plan's dependencies.
  - Use `bd search` before creating anything, to avoid duplicates.
- Claim each bead when you start it and close it only once it's verified.
- Start with 1A.1: typed section serializers and removing the stale `serialize` fallback in AppModel. Every later mutation depends on it.
- Phase 1A and 1B can go in either order; 1C needs the 1B components.
- **Checkpoint:** when Phase 1 is complete, stop. Report what landed and send simulator screenshots of the new shell, the design gallery (light and dark) and the Home tab. Wait for my go-ahead before Phase 2.
- After that, work through Phases 2-4 stream by stream, reporting at the end of each stream.

## Non-negotiable rules (full list in plan section 3)
Persistence and data:
- Every mutation: update memory, then `await persist([...])`, then return the verified Bool.
- Each new mutable section gets a typed serializer and a `serialize` case.
- Patch record `raw` JSON in place. Keep unknown keys and unreadable rows verbatim.
- New records use Dart toJson key order and double lexemes.
- A cascade across sections is one commit.
- The store must stay loadable by the Flutter app (users may downgrade).

Dates, numbers and strings:
- DartDateTime and DartCalendar only.
- No Date arithmetic, no Calendar.current, no DatePicker for month math.
- The clock comes from AppModel.now.
- Display formats are fixed en_US.
- Money goes through model.moneyFormatter (hide balances).
- Percentages use DartFixed.
- Reject non-finite numbers.
- UTF-16 comparisons where Dart compares strings; Dart-style trim; stable sorts.

Code and UI:
- No third-party dependencies; Swift 6; @Observable; Provider-style simplicity, no new abstraction layers beyond what the specs name.
- Every animation needs a Reduce Motion path.
- VoiceOver labels on charts and cards.
- Dynamic Type via Font.custom(_:size:relativeTo:).

## Verification (run before closing any bead)
- `cd native/BudgieCore && swift test`
- After any project.yml change: `cd native && xcodegen generate`.
- Build and run the app tests on the "iPhone 17" simulator (UDID B6FD49DA-9E30-46BB-9BAC-DB51AEEDF6B4), scheme Budgie, project native/Budgie.xcodeproj. Build it for "iPhone 17 Pro Max" too.
- Parity:
  - `native/ParityHarness/run.sh generate` when you add Dart-oracle fixtures (every ported calculation needs one).
  - `SWIFT_OUT=<dir> native/ParityHarness/run.sh verify` for every mutation that writes a section. It proves Flutter still loads what Swift wrote.
- UI changes: launch on the iPhone 17 simulator and check with screenshots. Compare against the Flutter screenshots in native/docs/research/screenshots/.
- Demo data: copy native/Fixtures/store/typical/input into the app container's Library/Application Support/financial_store. That fixture enables App Lock and EUR/de_DE and contains edge-case rows, so for visual review make a cleaned copy:
  - Set appLockEnabled false, currency USD, localeOverride null.
  - Drop the 12 junk transactions.
  - Recompute payloadLength and payloadChecksum (FNV-1a 64, signed-hex format; see StoreFile.checksum).
  - Keep it outside the repo.
- Never install on the "iPhone 17 Pro" simulator. It holds seeded Flutter data under the same bundle id, and installing would migrate it.

## Git
- Commit each verified step on this branch, with a clear message.
- Stage files by name.
- No --no-verify, no force push, no amend, no history rewriting.
- Don't push or open a PR unless I ask.
- If PARITY_GAPS.md, AGENTS.md or MIGRATION_SPEC.md become inaccurate because of your change, update them in the same commit.

## Security note
The plan's section 7 lists a leaked 2023 OpenAI key in this public repo's history. I'm handling revocation; don't touch git history. Never commit anything under .env, Secrets.xcconfig or .beads/.

Report tersely: what changed, what you verified (with command output for failures), and anything that needs my decision.
