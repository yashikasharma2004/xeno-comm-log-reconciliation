-- ============================================================================
-- Comm-Log Send Reconciliation — merchant_id = 501, October 2026, Diwali campaigns
-- Target: reproduce Finance's reported target_base = 22
-- ============================================================================
-- Logic (per README.md):
--   1. A campaign only counts if its creation workflow is finalized
--      (creation_status IN 'approved','aborted','resumed','stopped') AND
--      processing_status = 'processed'.
--   2. Campaigns form retry chains via parent_id (A -> B -> C = one underlying
--      communication, re-attempted). Within a chain, count each DISTINCT
--      customer once, no matter how many attempts it took.
--   3. A standalone campaign (no parent, and nothing retries off it) has no
--      chain to collapse into — every send row is its own qualifying event,
--      even if the same customer appears more than once.
-- ============================================================================

WITH RECURSIVE
-- Walk parent_id links up to find each campaign's ultimate chain root.
chain_root(id, root_id) AS (
    SELECT id, id FROM campaign WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, cr.root_id
    FROM campaign c
    JOIN chain_root cr ON c.parent_id = cr.id
),

-- Keep only campaigns that have actually cleared approval + processing,
-- and flag whether each belongs to a chain or is a true standalone.
eligible AS (
    SELECT
        c.id,
        cr.root_id,
        CASE
            WHEN c.parent_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM campaign p WHERE p.parent_id = c.id)
            THEN 1 ELSE 0
        END AS is_standalone
    FROM campaign c
    JOIN chain_root cr ON cr.id = c.id
    WHERE c.merchant_id = 501
      AND c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND c.processing_status = 'processed'
),

qualifying_sends AS (
    SELECT
        e.root_id,
        e.is_standalone,
        cl.id AS log_id,
        cl.customer_id
    FROM communication_log cl
    JOIN eligible e ON cl.communication_id = e.id
    WHERE cl.merchant_id = 501
      AND cl.communication_type = '2'                 -- Campaign sends only
      AND strftime('%Y-%m', cl.sent_time) = '2026-10'  -- October 2026
)

SELECT
    -- standalone campaigns: every row is its own event
    (SELECT COUNT(*) FROM qualifying_sends WHERE is_standalone = 1)
    +
    -- chained campaigns: one qualifying send per distinct (chain, customer)
    (SELECT COUNT(DISTINCT root_id || '-' || customer_id)
     FROM qualifying_sends WHERE is_standalone = 0)
    AS target_base;

-- Result: 22
