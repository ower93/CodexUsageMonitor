# Codex Usage Monitor 2.0 implementation and acceptance

Status: **2.0.1 (10) installed locally at `/Applications/CodexUsageMonitor.app` on
2026-11-03 (Asia/Shanghai). Authentication rejection now triggers one bounded
app-server reconnect. All 107 tests / 24 suites passed; the installed app's
runtime log confirms live quota, account and thread sources. Package signatures,
SQLite integrity and all 2,779 pre-install frozen groups passed verification,
including the 1,932 originally restored groups. The prior 100-test result and
two-hour resource evidence are retained, not relabeled as new tests.
Physical sleep/wake, actual offline recovery and full external Data Health /
VoiceOver acceptance remain open. No public release was made.**
Updated 2026-11-03 (Asia/Shanghai). Branch: `codex/usage-monitor-2-0`.

Current scope, clarified by the owner on 2026-10-06: continue iterating locally;
public release is not required. The v2.0 objective is trustworthy local monitoring,
interactive analytics, and reliable everyday operation on this Mac. Signing,
notarization, public update infrastructure and other-device release validation
are deferred and must not block this local objective.
This file is the acceptance ledger, not proof that unchecked work is complete.
On 2026-10-12 the owner requested completing acceptance and then replacing the
installed app. This authorizes a backed-up local installation after acceptance;
it does not authorize claiming outstanding hardware/VoiceOver checks as passed.
The owner subsequently chose “暂时不方便，先完成其他验收”: do not put the Mac to
sleep, disconnect its network or change its power settings for this follow-up.
On 2026-10-17 the owner explicitly requested local installation despite these
remaining checks, then approved restoring the saved historical ledger when the
installed app and its data directory were found absent on the current machine.
On 2026-11-03 the owner authorized fixing authentication recovery and replacing
the locally installed app. This does not expand the deferred public-release or
disruptive hardware-test scope.

## Scope and invariants

- Keep native SwiftUI/AppKit, the approved glass style, Chinese/English, regular
  English typography, local processing, and existing Codex authentication.
- Never show preview figures as real data. Missing is not zero.
- Distinguish account-reported quota/activity from locally observed usage and
  estimated API-equivalent value. API equivalent is not a bill or proven saving.
- Preserve frozen historical prices and amounts. Changes to historical accounting
  require backups and an auditable correction/backfill path, not silent repricing.
- Never mutate Codex authentication, config, threads, or source session logs.
- No new model calls, cloud sync, GitHub push, public upload or release in this
  implementation unless separately authorized.
- Optional future billing-provider integration and speculative AI insights are
  explicitly deferred in the approved proposal, not required for 2.0.

## Acceptance ledger

| ID | Requirement | Evidence required | Status |
|---|---|---|---|
| T1 | Loading/live/stale/unavailable/demo separated; empty startup | SourceHealth/UsageStore tests; empty and demo native renders | Local pass |
| T2 | Independent limits/account/threads/cost status and freshness; null preserved | Partial-success and stale-source fixtures; separate opt-in live quota check | Local pass; not every live provider method guaranteed |
| T3 | Multi-bucket limits, selected menu quota, legacy fallback | SourceHealth and decoder tests; settings render | Local pass |
| T4 | Versioned model pricing including GPT-6 Sol/Luna and GPT-6.1 Sol | Official catalog checked 2026-10-06; exact-ID/snapshot/frozen-history tests | Local pass |
| T5 | Resolve September child counter and rejected-increment audit | 11/11 child baselines and 3/3 root checkpoints recovered on in-memory copies; abnormal categories unpriced | Read-only audit pass; no production history rewritten |
| T6 | Separate pricing coverage from ingestion health | Accounting/source tests and native Data Health render | Local pass |
| T7 | Explicit source, local lifetime, Monday/local-time week, honest recent-chat labels | CurrentWeek/time zone tests; bilingual renders and docs | Local pass; recorded days are not rebucketed after a time-zone change |
| A1 | Native resizable analytics window: Overview/Chats/Models/Data Health | Live Overview/Chats/Models navigation; Data Health native render and component AX tests | Partial: named metrics and native editor focus pass; external Data Health traversal remains blocked |
| A2 | Date and model filters; searchable/sortable chats; parent/child drill-down without double count | Aggregation/filter/cycle tests; model/date drill-down and chat selection | Local pass |
| A3 | Daily tokens/cost charts, linked selection, equivalent prior-period comparison | Complete-day comparison tests; actual chart click links day/stats/chats | Local pass |
| A4 | Amount inspector: categories, frozen price/version, backfill and exclusions | Reconciliation tests; exact-price inspector and keyboard selection | Local pass |
| A5 | Privacy-safe CSV/screenshot export; privacy mode and persistent filters | Redaction/formula tests; actual CSV/PNG Save panels and artifact inspection | Local pass; privacy mode is pseudonymization, not full anonymization |
| A6 | SQLite query layer and transactional ingestion/import preserving history | Exact import, no-duplicate, rollback, future-schema rejection tests | Local pass |
| B1 | Codex executable diagnostics/override and CODEX_HOME support | Environment/resolver fixtures and live app-server diagnostic | Local pass |
| B2 | Notifications when available, polling recovery, backoff, sleep/wake/low-power behavior | Scheduler/race/notification tests; 20 simulated sleep/wake and 10 transport-failure recovery cycles; native file events; bounded authentication reconnect fixtures | Local pass; installed build 10 reads all three live sources; physical sleep/wake, actual network toggling and battery-device behavior pending |
| B3 | Debounced incremental indexing and bounded cancellation | Identical-snapshot/ledger benchmark and historical-price invariants; normal-frequency resource run | Local pass: cold rebuild 60.9 s in matched benchmark and 58.9 s in packaged app; warm benchmark 0.6 s; two-hour soak passed with 475 samples |
| B4 | Price catalog integrity, offline fallback, optional signed catalog updates | Signature/tamper/rollback/rate-version/offline-cache tests | Local pass; maintainer key not provisioned |
| D1 | Compact screen-fitting menu panel, readable warnings, native table/chart accessibility | Chinese/English, light/dark, compact settings, empty UI, keyboard and chart tests | Partial: full VoiceOver/small-screen hardware coverage pending |
| R1 | Optimized 2.0 app and reproducible local packaging | arm64 release build, nested signatures, resource audit, actual launch | 2.0.1 build 10 installed locally; live-source and frozen-history checks pass; broader daily-use/macOS 14/Intel validation deferred |
| R2 | Developer ID signing, hardened runtime, notarization | Signature, accepted notary submission, stapler/Gatekeeper | Deferred by owner; not a local acceptance gate |
| R3 | Secure in-app updates with Sparkle; signed update verification | Sparkle 2.10.0 embedded; missing feed/key disables updates; signed-feed and pre-extraction policy required | Integration retained but disabled without configuration; public update validation deferred |
| R4 | Current bilingual README/screenshots and operating/data docs | Both panel screenshots include cost; native analytics previews; operating/release docs reviewed | Local pass; explicitly labeled candidate, not published release |

“Local pass” is scoped to the tests and machine above, not a claim of public
distribution readiness or exhaustive cross-version compatibility.

## Current evidence

### 2026-11-03 authentication recovery and local replacement — build 10

Times in this section are **Asia/Shanghai**. Private evidence is retained in
`work/auth-reconnect-20261103/` (Git-ignored, directory mode 0700).

- Diagnosis: the monitor's long-running app-server returned an authentication
  RPC error (`401` / `token_revoked`). A fresh connection to the current CLI
  could read usage. The old client treated the error as a valid transport
  response, so it kept reusing the rejected helper instead of loading the
  current authentication state. This was not evidence that the usage endpoints
  had been removed. The regression was reproduced before the fix in
  `regression-red.log`.
- `CodexAppServerClient` now recognizes authentication errors only in the quota
  and account RPC error objects, shuts down that helper and retries once from
  the configured executable path. It reuses the new healthy helper afterward.
  Repeated authentication rejection closes the failed helper and returns the
  independent source statuses; a failed reconnect retains already successful
  partial responses. Unsupported methods, rate limiting, server errors and
  successful payload text do not trigger authentication recovery. Shutdown and
  cancellation remain bounded. The monitor does not edit Codex credentials or
  configuration; if Codex itself has no valid login, automatic reconnection
  cannot replace signing in again.
- `full-tests.log`: **107 tests in 24 suites passed**, including five new helper
  lifecycle scenarios and two parameterized authentication classifiers (16
  cases). Coverage includes revocation after a healthy read, account-only auth
  failure, persistent rejection, unsupported quota methods, and replacement
  transport failure with preserved partial data. These are deterministic
  fixtures, not deliberate revocation of the owner's real login. This run does
  not relabel the prior opt-in native AX/live-provider acceptance as rerun.
- Built the release-optimized **arm64 2.0.1 (10)** app with the installed Swift
  toolchain and macOS 26.5 SDK. Initial toolchain/macro discovery failures were
  resolved by using that existing SDK and the installed Testing macro plugin;
  no toolchain was installed or system selection changed. The package script
  now honors an explicit SDK override. Sparkle/resources are included and
  nested `codesign --verify --deep --strict` checks pass. This remains an
  ad-hoc-signed local build, not a notarized or public release.
- At **13:50:24**, the previous production app PID **89760** and its owned
  helper PID **89787** shut down normally. The saved runtime log includes the
  coordinator shutdown and application termination. Only the ledger and its
  last-good backup plus monitor preferences were copied before replacement;
  no whole-project or database backup was created. The prior build 9 binary
  matched the already retained October 17 candidate, which remains the rollback
  artifact. The new bundle was staged on the Applications filesystem and moved
  as a whole bundle; no files were merged into the old app.
- The installed executable SHA-256 is
  `bbcedd3b5448d0d8db4a6ef7ef602f8a7ddf9199d291de9b1c254264273ee7e3`.
  It was launched with `open -n /Applications/CodexUsageMonitor.app --args
  --analytics`, without demo or isolated-data overrides. New app PID **34279**
  owns one helper PID **34288**, loaded from the configured current CLI
  **0.166.0-alpha.5.1**. At **13:50:27**, the installed app itself logged
  `Usage sources live: quota=true account=true threads=true`. This is live
  source/decoder verification, not merely a process-alive check or a separate
  CLI probe. UI accessibility/VoiceOver was not revalidated in this patch.
- The normal startup scan completed in **756 ms**, reading the 174-file local
  index (172 unchanged, 434 reported ingestion issues, available=true). This
  is a warm-start observation, not a new cold-index benchmark or proof of full
  history coverage. Accounting/ingestion behavior and price logic were not
  changed by this patch.
- `frozen-history-install.json`: all **2,779** pre-install frozen-price groups
  survived, **2,777 unchanged** and **2** with new increments at their existing
  rates. No missing/repriced, regressed or inconsistent-cost groups; schema
  unchanged. `frozen-history-restored.json` independently checks the original
  **1,932** restored groups: **1,927 unchanged**, **5** with legitimate
  append-only increments, no price regressions. `sqlite-integrity.txt` is `ok`.
  Existing language, privacy, filters and CLI override were retained; only the
  reopened window's saved vertical coordinate changed by one point.
- The scoped log collector was stopped, leaving only the new installed monitor
  and its one owned helper running. A checksum-based, symlink-preserving dry-run
  comparison found no differences between the old staged bundle and the retained
  build 9, or between the new candidate and installed build 10. The task's
  duplicate staging/candidate bundles and 454 MB temporary build cache were then
  removed; small private test logs, ledger snapshots and installation evidence
  remain. No other app copies, archives or user data were cleaned up.

No GitHub push/release, login reset, deliberate credential revocation, actual
network disconnection, hardware sleep, new two-hour soak or battery-energy
measurement was performed. Previously documented hardware and full VoiceOver
gaps remain open.

### 2026-10-17 local installation and history restoration — build 9

All times in this section are **America/Los_Angeles (PDT)**. Private evidence is
in `work/local-install-20261017/` (Git-ignored, directory mode 0700).

- Preflight found **no** `/Applications/CodexUsageMonitor.app`, production
  support directory, preference domain, or running monitor process. The repository's
  `dist` bundle is an old 1.2.2 (5) artifact and was not used. This was a fresh
  installation into the production location, not replacement of a running 1.2.4
  app. No current installed application/data was silently deleted or overwritten.
- Installed the exact retained **2.0 (9)** production-ID archive from the October
  13 evidence. ZIP SHA-256 and CRC matched; the executable still hashes to
  `2f5b48430b16fa066a9da8def35f4420528a054b89bfdd6bffb13024d33db6e1`.
  All nested signatures passed `codesign --verify --deep --strict` before and
  after installation. It was staged on the Applications filesystem and moved
  as a whole bundle. This is the previously tested release-optimized, ad-hoc
  local build; it was not rebuilt, notarized, or publicly released today.
- With the owner's explicit approval, restored the ledger and its last-good
  backup from `work/local-followup-20261013/backup-snapshot-20261013-004622/`.
  All six files in that archive matched its saved SHA-256 manifest, but only
  the two ledger files were installed. Obsolete indexes, legacy backup files
  and old preferences were not imported. The original archive, extracted input,
  and `ledger-before.json` remain untouched recovery evidence. The production
  data directory is mode 0700; restored ledger files are mode 0600.
- The current CLI is **0.163.0-alpha.10.2** in
  `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`.
  Configured only the monitor's existing `codex.executableOverride` preference
  to this executable; no Codex authentication/configuration/source log was edited.
  The default resolver in this build does not automatically discover ChatGPT.app.
  Normal launch uses the production data directory, no demo or QA-data override.
- First launch at **06:53:30** opened the actual Overview window with local
  data and privacy mode enabled. `installed-runtime.log` confirms a real scan:
  **4,305 ms, 106 files, 155 ingestion issues, available=true**. This machine has
  a different available log set from the prior 2,100-file test; 4.3 seconds is
  **not** an apples-to-apples speedup or evidence of complete historical coverage.
- `frozen-history-final.json` compares the untouched 1,932-record restored input
  with the saved 2,070-record post-install ledger. All **1,932 frozen groups**
  survived; five groups acquired legitimate new increments priced at their
  original rates, and 138 new groups were added. Maximum USD rounding discrepancy
  is `2E-14`; no silent repricing was detected. SQLite `integrity_check` returned
  `ok`, schema 1, ledger revision 3195, and 2,070 rows at the recorded check.
- `live-rpc.json` is a **separate read-only CLI smoke test** using the installed
  source's initialization and request shapes, not a menu-bar screenshot. All
  three endpoints (`account/rateLimits/read`, `account/usage/read`, `thread/list`)
  succeeded. The returned quota contained a 10,080-minute window with 44% remaining.
  The diagnostic child PID 51948 exited normally on stdin EOF (exit 0). No model
  requests were made. This does not claim every future response shape is supported.
- The first installed app PID 50766 and its one owned helper PID 50768 exited
  through normal coordinator shutdown at **06:56:47**, without force kill or
  orphan. Saved `installed-data-after-first-launch.zip` while they were stopped;
  its ZIP CRC passed and SHA-256 is
  `aa0023023c7ed40669f0f80e9c3251fb105aabe5f2a5f5dd73335db090dba9e7`.
  This captures the new data, so a future rollback must not overwrite it with
  the older restored ledger. Restart used the same installed bundle and data.
- Restarted app PID **51989** had exactly one helper PID **51992** at final
  inspection. Warm startup scanned in **117 ms**; a native toolbar Refresh
  triggered another **107 ms** scan (106 files, 103 unchanged). The real Overview
  reopened and displayed updated totals. The scoped log collector was stopped;
  the installed application and its helper were intentionally left running.
- A single Data Health traversal on this machine again crashed the **UI inspection
  helper**, not the app. Diagnostic
  `SkyComputerUseService-2026-10-17-065510.ips` identifies `EXC_BREAKPOINT/SIGTRAP`
  and `Array.remove(at:)`. The app and its helper remained alive; returning to
  Overview after the planned restart was verified. This is not a full-page
  accessibility/VoiceOver pass and no further Data Health retry was made.

The prior **100 tests / 24 suites**, frozen-history checks and **October 6
two-hour resource run** remain dated evidence for their respective artifacts.
No new two-hour soak or battery measurement was performed. Physical sleep/wake,
actual network disconnection/recovery, low-power/battery endurance and complete
VoiceOver remain unverified. No GitHub push/release, new automation, security
permission change, system sleep or network disruption was performed.

### 2026-10-13 non-disruptive follow-up — build 9

Private evidence is in `work/local-followup-20261013/` (Git-ignored, directory
mode 0700). No whole-machine sleep, network disconnection, power-mode change,
public release or production installation was attempted.

- Native interaction exposed a real keyboard defect: the custom AppKit lifecycle
  had no standard Edit/File menus, so Command-A did not select the search text
  and Command-W did not close the analytics window. `UsageApplicationMenu` now
  supplies native responder-chain actions for undo/redo, cut/copy/paste, select
  all, close window and quit, with Chinese/English titles. The app observes only
  language changes to rebuild its menu; it does not duplicate SwiftUI edit state
  or intercept global keyboard events. Runtime accounting and pricing are unchanged.
- `tests-final-build9-live.log`: **100 tests in 24 suites passed**, including the
  original native AX/audit opt-ins, an actual account quota read, and three new
  menu contract tests. The latter verify normal first-responder targets, command
  key modifiers, bilingual titles and distinct window-close/application-quit
  actions. The earlier 99-test build is retained as intermediate evidence.
- Actual native UI, synthetic-data-only: side-bar and chat-row arrow navigation,
  no-result search and clearing, parent/child grouping and amount inspection were
  checked. The This Week view on Tuesday October 13 contains Monday October 12
  and Tuesday October 13; like-for-like comparison excludes the current day.
  After the fix, Command-A visibly selected all of `keyboard-check`; deletion
  restored the unfiltered totals, Command-Z restored the search text and empty
  result, and Command-Shift-Z cleared it again. These observations are recorded
  in `native-interaction-notes.md`, not described as a full VoiceOver pass.
- Command-Q on the isolated demo process PID 6141 produced an explicit native
  `App quit` result. `qa-keyboard-quit.log` confirms normal coordinator shutdown
  and `Application will terminate` at 00:44:29 Asia/Shanghai. The final
  Command-W attempt produced a window-state timeout while demo PID 7415 remained
  alive. The window-close action contract passes, but that timeout alone is not
  counted as independent external window-visibility verification.
- `handoff-rehearsal-build9.json`: a fresh, hash-stable snapshot of installed
  **1.2.4 (7)**, its six monitor-data files (1,932 ledger records), and exported
  preferences was saved in
  `work/local-followup-20261013/backup-snapshot-20261013-004622/`.
  ZIP extraction preserved file hashes, modes and symlinks; restored app
  signatures passed and the copied index/ledger revisions matched. This was a
  stable running-app snapshot, **not the final stopped-app installation backup**.
- The same rehearsal used a private temporary directory, not `/Applications`:
  an injected missing-stage failure restored the old bundle; replacement by
  **2.0 (9)** and an app-only rollback restored the exact old bundle. A separate
  post-upgrade ledger copy remained byte-for-byte unchanged through app rollback.
  This validates file handling, not the actual installer or runtime downgrade
  compatibility. Never roll an older ledger over subsequently recorded usage;
  retain both generations and explicitly reconcile any required data restore.
- `package-final-build9-candidate.log`: final release-optimized production-ID
  candidate passed deep/strict signature verification and ZIP CRC validation.
  Retained archive:
  `work/local-followup-20261013/CodexUsageMonitor-2.0-build9-local-candidate.zip`.
  ZIP SHA-256: `32a65f490c6964d27388b13bc06e8de951e6a7d8446d7624fb6f8945a891443e`.
  Executable SHA-256: `2f5b48430b16fa066a9da8def35f4420528a054b89bfdd6bffb13024d33db6e1`.
  It is ad-hoc signed for local use, not notarized or publicly published.

The October 6 two-hour run and October 12 real-data frozen-history verification
remain prior-build evidence; neither was rerun or relabeled as a build 9 soak.
The only runtime change in this follow-up is native command routing. Full Data
Health traversal/VoiceOver was not retried after the previously documented helper
crash. Physical sleep/wake, actual offline recovery and low-power/battery behavior
remain unverified. At the end of this follow-up production remained **1.2.4 (7)**; its PID was 980,
not the stale PIDs in older evidence. Take a new stopped-app backup immediately
before any later authorized installation; this rehearsal does not install it.

### 2026-10-12 installation acceptance — automated checks pass; manual gates open

Fresh private evidence is in `work/local-install-20261012/` (Git-ignored, directory
mode 0700). The old temporary candidate/build directories had been cleaned up,
so the candidate was rebuilt from the current source using Swift 6.4/Xcode 27,
release optimization and two build jobs. Only a test harness changed in this
iteration; application runtime code and historical pricing were not modified.

- The first full run (`tests.log`) had 96 passes and one `.responseTimedOut` in
  `repeatedOfflineTransportFailuresRecoverWithoutRestartingTheClient`. A focused
  rerun and a full unchanged rerun passed, but the 0.5-second fixture timeout
  recurred while the real cold-index scan was active. This was an async timing
  failure, not evidence of an actual network recovery failure. The recovery test
  now uses the same 2-second response allowance as its neighboring lifecycle
  tests and explicitly shuts down its helper on thrown errors. Its ten recovery
  cycles and all assertions are retained; the dedicated timeout/teardown test
  and production 12-second response timeout are unchanged.
- `tests-final-live.log`: **97 tests in 23 suites passed**, with native AX,
  September reconciliation and live account diagnostics explicitly enabled.
  Both languages exposed all 12 required metrics; native editor name/focus/binding
  passed. The audit still recovered 11/11 children and 3/3 roots on copies and
  retained four ambiguous slices. The live Swift client received a finite quota
  value and valid window duration, then shut down its helper. This does not claim
  every optional account endpoint succeeded or that offline recovery was tested.
- `lifecycle-recovery-fixed-1.log` through `-5.log`: five additional successful
  repetitions, totaling 50 injected disconnect/recovery cycles. These remain
  simulations, not physical network testing.
- A fresh copy of the current production ledger (1,920 records) was placed in
  `/tmp/CodexUsageMonitor-install-data`. The isolated QA bundle used a separate
  bundle ID and this explicit data directory. Existing Codex logs were read as
  sources; no production ledger was used as an output. The packaged app rebuilt
  its empty index over **2,100 files in 45,346 ms** and produced a valid SQLite
  projection with 2,806 records (`PRAGMA integrity_check` = `ok`, schema 1).
  Later scans took **541 ms** and **466 ms**, skipping 2,096 and 2,098 files.
  This is a current-machine observation, not a controlled cold-disk comparison.
- `frozen-history-final.json`, generated by the saved read-only verifier, confirms
  all **1,920 frozen price/category groups** survive; 11 groups gained legitimate
  increments valued at their original frozen prices and 886 new groups were
  added. Maximum USD floating-point discrepancy was `2E-14`. No silent historical
  repricing was detected. The scan separately reported **928 ingestion issues**;
  this is not proof of complete historical coverage and must not be described as
  100% ingestion. The native Overview showed actual local records, not demo data,
  and manual Refresh updated the displayed values.
- `qa-live.log` records the one QA app PID 73729 and its helper PID 73741 from
  launch through normal coordinator shutdown at **15:58:37 Asia/Shanghai**.
  Both were absent after SIGTERM-triggered graceful cleanup, without force kill.
  A final spot sample was app/helper CPU 0.0%/0.0%, RSS 44,800/33,456 KiB and
  numeric FDs 18/31. These are **spot process resource samples, not a new soak
  run or battery-energy measurement**. The October 6 two-hour evidence is retained.
- Data Health external traversal remains blocked: the fresh demo attempt again
  crashed **SkyComputerUseService**, not the usage app. The saved macOS diagnostic
  `SkyComputerUseService-2026-10-12-155024.ips` reports `EXC_BREAKPOINT/SIGTRAP`
  with `Array.remove(at:)` on its faulting stack. Repeated tool retries are not
  counted as acceptance. Full-page keyboard/scroll and spoken VoiceOver require
  a manual check. No accessibility or OS security permission was changed.
- `package-candidate.log`: the production-ID **2.0 (8)** candidate at
  `/tmp/CodexUsageMonitor-install-candidate/CodexUsageMonitor.app` passed deep,
  strict nested-signature verification. A retained local ZIP passed CRC checking:
  `work/local-install-20261012/CodexUsageMonitor-2.0-build8-local-candidate.zip`.
  ZIP SHA-256: `d9953f474223ec33e07f217f24bb5afb436a327863de701734d3ab7597ca5464`.
  Executable SHA-256: `d04ddae87680ef17016494246077e29fbdd41388ef6e519307818cef7af6d58b`.
  This is ad-hoc signed local packaging, not notarization or public distribution.

The existing `/Applications/CodexUsageMonitor.app` remained **1.2.4 (7), PID 1014**
at the final check and continued its own refreshes. It was not stopped/replaced;
its ledger, preferences and Codex configuration were not intentionally written by
this acceptance work. No GitHub push, release, installation or new scheduled run
was performed. The owner was asked to coordinate physical sleep/network tests;
no response had arrived when these automated checks were completed. Next: finish
the real-device/manual gates, then take a fresh verified backup of the stopped
production app, monitor data and preferences immediately before installation.

### 2026-10-06 local performance/recovery iteration

Latest ignored evidence: `work/v2-local-20261006/`. This iteration never changed
the production app, ledger, authentication, configuration or source logs. Frozen
session snapshots use APFS clones; they are private test inputs, not public fixtures.

- `tests-final5.log`: **97 tests in 23 suites passed**, including
  `CODEX_USAGE_NATIVE_AX_TESTS=1` and `CODEX_USAGE_RECONCILE_AUDIT=1`.
- `index-buffered.log` versus `index-ordinal.log`: the same 2,042-file frozen
  snapshot (about 34 GB logical) and seed ledger, with deterministic accounting,
  took **103.501 → 60.903 seconds** for an empty-index rebuild (about 41% faster).
  Warm scans took 0.630 and 0.615 seconds. Both produced exactly equal sorted
  records/checkpoints and 895 separately reported ingestion issues.
- `index-repeat.log` and `index-final-history.log`: additional empty-index runs
  took 38.683 and 37.853 seconds with warm OS caches; those are repeat observations,
  not a promised cold-disk time. This benchmark does not flush the system cache.
  Test-command RSS that includes compilation is not the app's runtime RSS.
- `index-final-history.log`: all **1,846 existing price/category groups** retained
  their frozen prices and amounts; any extension of a group was exactly the new
  ordinary-input/cached-input/output delta valued at that same frozen price.
  The test does not claim every JSON row is byte-identical: new increments may
  extend an existing same-day/model/price group. Production history was not written.
  Final sorted records/checkpoints SHA-256 matched the prior optimized run:
  `aa4db544dd147f01dbce8e6dc53e2380de3670369f75e7460271f32d6c2db8ec`.
- The real packaged candidate's first empty-index scan was observed completing
  in **58,910 ms** across 2,044 files, `available=true`. Subsequent real-data
  ingestion was confirmed, including the 2,191 ms / 2,045-file scan saved in
  `soak-ingestion-early.log`. These observations establish actual work, not just
  idle process survival. The older approximate three-minute observation used a
  different live-data/workload state and is not the controlled comparator.
- Reader changes: 256 KiB bounded sequential reads; newline-exact cursors;
  chunk-discard of irrelevant giant tool-output lines; a conservative 512-byte
  envelope filter that recognizes numeric `ordinal` headers. Unknown layouts
  still use the full parser. Partial final lines remain uncommitted; append,
  CRLF, oversized Chinese text, early stop and cancellation are covered.
- The comparison exposed a separate nondeterminism bug: continuation files can
  share a session ID, and dictionary order selected an arbitrary parent history.
  Enumeration is now stable; all parent continuations supply latest pre-fork
  evidence, never added counters. Conflicting same-time evidence remains unknown.
  Disposable index schema 4 forces one rebuild; ledger/price schema is unchanged.
- Lifecycle tests cover 20 routed sleep/wake notification cycles, event storms,
  observer cleanup and low-power routing; ten injected app-server disconnect /
  recovery cycles; stale-last-good and offline-first-launch behavior; and 20
  network-restoration signals during an in-flight request with no overlap.
  NWPathMonitor now requests an immediate retry after false-to-true connectivity,
  without treating a reachable path as proof that the API is available.
- Data Health exposes 12 named/value-bearing metrics in both languages, hides
  private paths in privacy mode, and has a named native path editor with verified
  text-field role, focus/resign and isolated-defaults edit binding. The metric
  rows needed explicit static-text traits to expose their values. Native editor
  accessibility properties are set directly, consistent with Apple's
  [AppKit accessibility customization](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol).
  Component tests mount the real view without its ScrollView; this is **not** an
  end-to-end VoiceOver or external traversal pass. Chinese/light and English/dark
  native renders (`health-final-*.png`) were visually checked without clipping.
- `package-final-local.log`: latest optimized 2.0 (8) bundle packaged with nested
  ad-hoc signatures verified, at `/tmp/CodexUsageMonitor-v2-final/CodexUsageMonitor.app`.
  The checked local archive is
  `work/v2-local-20261006/CodexUsageMonitor-2.0-build8-local-optimized.zip`;
  ZIP integrity passed and its extracted executable hash matches the bundle.
  Archive SHA-256: `54df0889d024a49567dadfeda8ef86a68204f47590491a56380921abc2501055`.
  Executable SHA-256: `11762419019b81be77fd5f565124c1e2b9efcae077521f709ed3fd3d1583526f`.
  Use explicit demo mode or isolated data; it has **not** replaced the production
  installation. The older candidate/hash below is retained as historical evidence.
- External native automation still returns `Sky Computer Use native pipe closed
  before response` when entering Data Health; the app stays alive. Repeatedly
  retrying that helper is not an acceptance strategy. Manual full-page scrolling,
  sidebar/toolbar keyboard traversal and spoken VoiceOver remain to be checked.
- An independent Xcode Accessibility Inspector check could select the demo
  process after restarting the inspector to refresh its target list. The
  demo-only `--qa-regular-app` flag makes the otherwise accessory app selectable;
  it does not change normal launches. All six audit options were enabled
  (description, hit region, contrast, detection, parent/child, action). Invoking
  Run Audit left the warnings area empty but exposed no verifiable completion
  marker, so this is **not recorded as a completed audit**. No macOS permission
  was added, and both scoped demo processes and the inspector were closed.

### Two-hour run — passed; verified 2026-10-06 Asia/Shanghai

The one authorized run completed **2026-10-06 10:53–12:53 Asia/Shanghai**, with
normal refresh intervals and no `--qa-profile`, on AC power with low-power mode
off. The driver returned **exit 0** and its final PASS at 12:53:16. There were
**475 samples**, from 10:53:02 through 12:53:01 (7,199 seconds between first and
last sample), with 15–18 second sample gaps. The final sample was followed by
the normal 15-second sampling wait and graceful shutdown; the planned
7,200-second deadline was reached. No new run was started for this verification.

App PID 76651 and helper PID 76708 were stable throughout. The driver checked
exactly one helper on every sample and verified graceful termination without
forced cleanup or an orphan. Both PIDs and the scoped app/driver were absent
when independently rechecked; production PID 1088 was still running unchanged.
The app-server/source reads were read-only; ledger/index/database writes were
confined to the isolated test data directory.

| Sampled metric | App | app-server helper |
|---|---:|---:|
| CPU mean, including startup | 0.610% | 0.110% |
| CPU mean after first two minutes (467 samples) | 0.172% | 0.037% |
| CPU peak, including startup | 74.4% | 34.0% |
| RSS first / peak, KiB | 91,456 / 91,456 | 104,864 / 104,864 |
| RSS last, KiB | 33,552 | 30,624 |
| RSS last minus first, KiB | -57,904 | -74,240 |
| Open FDs first / peak / last | 17 / 17 / 13 | Not collected |

The app/helper RSS passed the configured 524,288 KiB peak and 131,072 KiB growth
limits. App FDs passed the 256 peak and 16 growth limits. Helper FD counts were
not sampled, so no helper-FD acceptance is claimed. The CPU means are arithmetic
means of `ps` samples, **not measured energy use or a battery-life result**.
Other local work ran on the same Mac; this was not a controlled power benchmark.
No unbounded resource growth was observed in this bounded run; it is not proof
against every possible leak or all-day workload.

Actual ingestion is evidenced by `soak-ingestion-early.log`: at 11:09:05 the
same app PID completed a 2,191 ms scan of 2,045 files, 2,031 unchanged,
`available=true`. Its 904 existing ingestion issues remain explicitly reported;
resource-test success does not certify complete historical data coverage.

- Bundle: `/tmp/CodexUsageMonitor-v2-local/CodexUsageMonitor.app`.
- Original sampled report: `/tmp/codex-usage-v2-soak.oQgr3D/resource-soak.csv`.
- Preserved byte-identical report: `work/v2-local-20261006/resource-soak-final.csv`.
  SHA-256: `6aed48d360825c9b9b03099639c659999bca8140e365d3b4d7cc4150cc807704`.
- Driver result: `work/v2-local-20261006/resource-soak-tmp.log`.
  SHA-256: `058bef8499c2bb5cbf92b2feba34777daf67e330f771acfc58d52a7821cf33b9`.
- This chat's finite follow-up `codex-usage` reached its terminal verification
  and was confirmed **PAUSED at 13:19 Asia/Shanghai**. No new test was scheduled.
- This bundle has the same indexing/lifecycle core as the final UI candidate;
  later changes are Data Health accessibility/tests and a guarded demo-only
  Dock-entry switch for Accessibility Inspector, inactive in normal mode.
- The running resource script was not edited. No production app, ledger, Codex
  configuration or source log was modified. This did not install or publish v2.
- An earlier Documents-based run (`resource-soak.csv` / `resource-soak.log` in
  the evidence directory, not the `/tmp` report above) stalled in a file open
  and was stopped. It is **invalid/aborted**, not performance evidence. The
  `/tmp` data directory avoids that protected-folder interaction without changing
  any macOS permissions.

Actual whole-machine sleep/wake and network disconnection have not been triggered
without the owner's participation. Injected failures/notifications do not stand
in for those hardware checks. An AC run also does not certify battery life.

### Earlier baseline evidence

Local, ignored evidence is under `work/v2-implementation/` and is not intended
for public upload. Private source logs and the ledger backup are not test fixtures
to commit. Public previews in `outputs/` contain only synthetic data.

- `tests-final.log`: **82 tests in 18 suites passed**, with
  `CODEX_USAGE_RECONCILE_AUDIT=1`. Other live-account tests remain opt-in.
- `reconciliation-final.log`: 11/11 child histories and 3/3 root checkpoints;
  four ambiguous slices retained as unpriced. The source logs have grown since
  September, so this validates recovery from captured checkpoints, not an exact
  reconstructed September bill. All qualifying continuation histories are checked.
- `live-check.log`: the opt-in Swift client reads live rate limits and shuts down
  its child. It does not imply all optional account methods are supported.
- `resource-check-final.csv`, `resource-final.log`: 100 seconds, quota/cost intervals
  accelerated to 10/30 seconds on a copied data directory. Parent RSS
  **101,456 → 98,224 KiB**, peak 101,456; 12 open FDs throughout. One stable helper;
  graceful termination with no orphan. These numbers exclude the helper's RSS
  from the parent figure; helper samples are in the CSV.
- `ui-demo-filtered-20261006.csv` and `.png`: actual Save-panel exports; a selected
  model/day has exact USD 2.11809800 in CSV, rounded $2.12 in the picture; names
  and IDs are pseudonymized. CSV has actual CRLF, not escaped newline text.
- `package-final.log`: optimized 2.0 (8), arm64, nested bundle signature checks.
  The app contains its icon, pricing catalog, Sparkle and third-party license
  notices, not private logs or auth. The license is byte-identical to the pinned
  upstream 2.10.0 source; preflight checks its presence.
- `running-guard.log`: packaging refuses an active destination even when `/tmp`
  and `/private/tmp` spell the same physical bundle differently.
- `release-preflight-final.log`: correctly fails four public-release gates:
  Developer ID/runtime, stapled ticket, Gatekeeper trust, and update configuration.
- Actual final bundle launch: native Overview visibly shows synthetic $64.26 and
  27.82M tokens; menu and analytics demo costs use the same underlying records.
- Separate same-Mac clean-data launch through Launch Services, with an empty
  `CODEX_HOME` and empty usage-data directory: Overview shows estimated value
  `—`, zero **locally recorded** tokens, unavailable coverage ratios, and an
  explicit no-local-records explanation; no demo banner or demo amount.
  No credentials were copied. This is not a clean second-Mac installation test.
- `resource-check-normal.csv` / `resource-normal.log`: **960-second normal-mode
  warm run passed**, 2026-10-06 03:41:29–03:57 Asia/Shanghai; 95 samples, a copied
  data directory, no `--qa-profile`, low-power mode off. App RSS 76,960 → 25,136
  KiB (peak 76,960); helper 106,272 → 42,272 KiB (peak 106,272); app FDs 16 → 12.
  One helper throughout, both processes exited cleanly, no forced kill/orphan.
  Sampled `ps` CPU means were app 0.691% and helper 0.206%, including startup;
  these are sampling statistics, not an energy measurement or a multi-hour guarantee.
  Other local QA work occurred on the same desktop during the run.
- `normal-run-telemetry.log`: a normal-mode scan at 03:57:29 took 472 ms across
  2,039 files (2,028 unchanged), with existing ingestion issues reported separately.
  This proves actual scan work occurred during the bounded run, not just idle
  process survival. No task names, prompts, prices or credentials were logged.
- `resource-invalid-guard.log` / `resource-production-guard.log`: invalid/missing
  isolation returned exit 2 and left the already running test app (69403) alive.
  The cleanup trap now starts only after validation. That scoped probe and its
  helper were subsequently stopped cleanly.

Candidate: `/tmp/CodexUsageMonitor-v2-preview/CodexUsageMonitor.app`.
Binary SHA-256: `2ecb0c194ad48391a16a2209dbb1576fa543b364b403c0a04da59c3d417dc44a`.
The resource run used the same executable code before license-only resource
packaging changed the embedded signature (previous binary SHA-256
`09323d138c4d5c19b5922f69517e63836541cb870051da7f6d1cb5c66fdfaacf`).
This is a temporary, ad-hoc test artifact, not an installer. Use `--demo` or an
explicit isolated `CODEX_USAGE_DATA_DIR`; do not replace the production app yet.

The same final candidate is preserved locally as
`work/v2-implementation/CodexUsageMonitor-2.0-build8-local.zip` (ignored by Git),
so it does not depend only on `/tmp` surviving. Archive SHA-256:
`352ccec1fea8096500e53d61e2374c8d2b9fb0478a18971fd7513d8e0ac0432f`.
ZIP integrity, re-extracted nested signatures, executable hash and license copy
were checked. The final repackaged bundle also launched successfully in explicit
demo mode with the expected native Overview. This is still an unnotarized local
candidate, not a public download or production installation.

## Remaining local acceptance work

Cold-index optimization and the bounded two-hour resource run are complete.
Retain frozen-history and deterministic-replay checks for future parser changes.

1. Deferred by the owner for now: actual sleep/wake, network disconnection/recovery and low-power checks
   on this Mac when the owner can participate. Synthetic lifecycle/transport
   checks passed; physical behavior and battery endurance remain unverified.
2. Finish full Data Health accessibility/VoiceOver interaction. The UI automation
   helper `SkyComputerUseService` crashed while traversing this page's accessibility
   tree (`Array.remove(at:)`); the usage app stayed alive. Its native visual render
   passed, as have named/value-bearing component tests and native editor focus,
   but those do not substitute for full-page accessibility acceptance. Use a
   manual check rather than repeatedly crashing the helper.
3. Continue daily-use observation of installed 2.0.1 (10). Local installation,
   live-source reads and frozen-history preservation passed on November 3 as
   recorded above. The retained older bundle and ledger snapshots provide a
   rollback path, but runtime downgrade compatibility has not been tested.

## Deferred distribution work

Developer ID signing, notarization/stapling, Gatekeeper validation of a downloaded
artifact, a controlled HTTPS appcast and signing key, real signed old-to-new update
tests, and clean installation on other Macs/minimum macOS/Intel remain unverified.
These are future distribution tasks, not prerequisites for local iteration. The
existing update integration remains disabled without its required configuration.
Do not request distribution credentials or publish artifacts for the local scope.

The `/Applications` installation is **2.0.1 (10)**. Source publication was
separately authorized on November 3; it does not authorize a binary release,
signing identity setup, notarization submission or update-feed publication.

## Verified starting state

- Repository clean at `fe7bdbb`, installed app 1.2.4 (7).
- SwiftPM native macOS 14+; Xcode 27.0 / Swift 6.4 available.
- `security find-identity -v -p codesigning`: **0 valid identities**.
  Developer ID signing and notarization cannot be truthfully marked complete
  until the owner provisions an appropriate certificate and notarization access.
- Prior tests and audits are context, not fresh verification of version 2.0.
- Live UI inspection timed out during the proposal review; reattempt for acceptance.

## Work log

- 2026-10-06: Established clean baseline, feature branch, acceptance ledger and
  signing prerequisite. Begin T1–T4 with isolated fixture tests; do not install
  against the production ledger until accounting migration has passed.
- Implemented independent source health, current quota compatibility, versioned
  prices, unambiguous incremental accounting, SQLite analytics, native views and
  exports, event coalescing/backoff, signing-aware packaging and disabled-by-default
  Sparkle integration. Historical priced records remain frozen.
- Early resource runs exposed orphaned helper and termination deadlock; these
  were failures, not acceptance. The shutdown path and resource checker were
  corrected before the final successful run. A cold index reset took about three
  minutes with CPU bursts near one core and sampled memory much higher than warm
  steady state; this limitation is documented, not hidden by the warm test.
- A real FSEvents fixture exposed `/var` versus `/private/var` path mismatch;
  watcher roots now use physical paths. The final native event test passes.
- The first historical audit replay was nondeterministic because copied prefixes
  share metadata IDs. The test now resolves children exactly and checks every
  root continuation reaching the captured counter. An original file stopping at
  the checkpoint is not falsely claimed as a recovered increment.
- Final screenshot/demo consistency regression added. Full suite, isolated
  packaging, actual native launch, and public-release preflight completed with
  the evidence and remaining gates above.
- Continuation: resource runner now launches via Launch Services with explicit
  isolated environment forwarding and records/checks helper RSS as well as app
  RSS. Missing/production data-directory guards returned exit 2 as expected.
  The normal 960-second run completed successfully (exec session 77909; app 61386,
  helper 61423), and absence of both processes was verified after termination.
- The clean-data Data Health retry again crashed only SkyComputerUseService
  (03:43:24 diagnostic); usage-app PID 62769 remained alive. No full accessibility
  pass is claimed. Its scoped test instance was then asked to quit.
- After that benchmark ended, moved the resource runner's cleanup trap below
  validation. Both negative guards left an actual test app alive, then its scoped
  cleanup was verified. No running benchmark script was edited.
- Added complete third-party license notices and bundle preflight checks; rebuilt
  and verified the final candidate without changing app executable source.
- Distribution prerequisites remained absent across three consecutive goal
  turns. The latest check still reports zero valid signing identities and no
  configured appcast. No safe local action can supply the owner's certificate,
  notarization access, controlled update endpoint, another test Mac, or an
  operational accessibility test tool. Implementation remains a local candidate;
  the full public-release objective is not claimed complete.
- Resumed check on 2026-10-06: no signing identity or update configuration has
  appeared. Verified the final license-containing bundle launch and preserved
  a checked local ZIP. The original installed 1.2.4 instance remains untouched;
  the scoped demo test was stopped. Remaining release and external-validation
  prerequisites are unchanged; this is the first check after resuming the goal.
- Owner scope clarification on 2026-10-06: public release is not required; continue
  local iteration. The earlier distribution-blocked entries above are historical,
  not the current stop condition. Core development and bounded checks are complete,
  but cold-index resource work, longer real-use/recovery checks, remaining Data
  Health interaction acceptance and the backed-up local installation handoff remain
  open. Installed 1.2.4 (7) and PID 1088 were verified unchanged during this audit.
