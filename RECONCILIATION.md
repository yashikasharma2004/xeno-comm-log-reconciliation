# Comm-Log Send Reconciliation — merchant_id 501, Diwali campaigns, Oct 2026

**Reported `target_base` (Finance): 22**
**Reproduced value: 22** ✅

## Reconciliation Bridge

| Step | Description | Result | Reason |
|------|-------------|--------|--------|
| 0 | Naive count — `COUNT(*)` on `communication_log` for merchant 501, Oct 2026, across all 7 Diwali campaigns | **30** | Starting point: every raw send row, no filtering |
| 1 | Excluded campaign `9004` ("Diwali Cart Recovery - Retry C (pending)") | **26** (−4 rows) | `campaign.creation_status = 'approval_awaiting'` — per the data dictionary, a campaign that hasn't cleared approval doesn't count toward reporting, *even though* its `communication_log` rows already exist (send pipeline ran ahead of approval bookkeeping) |
| 2 | Collapsed duplicate customer attempts **within retry chains** to one qualifying send per customer | **22** (−4 rows: 3 from chain `9001→9002→9003`, 1 from chain `9201→9202`) | These aren't 2–3 independent communications — they're the *same underlying communication* re-attempted (`parent_id` chain). Customer `C2` was sent under `9001` (failed) then `9002` (delivered) — one qualifying send, not two. Same pattern for `C3` (3 attempts across `9001→9002→9003`) and `D1` (2 attempts across `9201→9202`). |
| final | — | **22** | Matches Finance's reported number |

**Note on what did *not* get collapsed:** campaign `9101` ("Diwali Flash Sale - Standalone") has customer `C20` appearing twice. This looks identical to the retry-duplication pattern above, but `9101` has no `parent_id` and nothing retries off it — it's a genuine standalone campaign, and the data dictionary is explicit that standalone sends don't collapse even on a repeated customer. Both `C20` rows are legitimate, separate qualifying events. (Naively deduping *all* repeated customers regardless of chain membership would have landed on 21, not 22 — the standalone/chain distinction is what makes the bridge work.)

## Final SQL

See [`reconciliation.sql`](./reconciliation.sql). Summary of logic:
1. Recursively walk `parent_id` to find each campaign's chain root.
2. Filter to campaigns where `creation_status` is finalized (`approved`/`aborted`/`resumed`/`stopped`) and `processing_status = 'processed'`.
3. For campaigns that belong to a retry chain: count `COUNT(DISTINCT root_id, customer_id)`.
4. For true standalones (no parent, no children): count every row (`COUNT(*)`).
5. Sum the two.

## What surprised me

The most interesting wrinkle was that campaign `9004` had `communication_log` rows already generated (4 sends, all delivered) *despite* its `creation_status` still being `approval_awaiting`. It would be easy to write a query that only checks `processing_status = 'processed'` (since the sends clearly went out) and miss that the creation/approval workflow hadn't actually signed off — silently inflating the count by 4. It's a reminder that "the send happened" and "the send is approved for reporting" are two different gates, and the pipeline doesn't enforce them in lock-step.

The second thing worth flagging: the standalone-vs-chain distinction (`9101`'s repeated `C20` vs. `9001`'s repeated `C2`/`C3`) looks superficially identical in the raw log — same customer, same campaign family pattern — and is only resolvable by checking `parent_id` relationships in the `campaign` table, not anything in `communication_log` itself. A dedup rule based purely on `communication_log` (e.g. "drop duplicate customer per campaign name prefix") would have silently under-counted the standalone campaign.
