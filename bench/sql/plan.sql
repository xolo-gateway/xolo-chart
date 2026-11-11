-- Puts the chaos providers of acme and globex under a subscription plan shaped
-- like a production one: three shared rolling windows (5 h, week, month)
-- anchored on a fixed schedule, fair-share thresholds, and a second key whose
-- week and month windows are moved by an override, so the plan checks read
-- one window start per key (xolo#230, xolo#231). The budgets are out of
-- reach: the plan meters and shares, it never refuses.
--
-- The chaos records already in the database become plan-covered history,
-- spread over the last 30 days and over both keys, and plan_usage_hourly
-- (and plan_usage_minutely, when present) is rebuilt from them as Xolo's
-- backfill does.
BEGIN;

WITH anchors AS (
  SELECT to_char(now() - interval '3 hours', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS h5,
         to_char(now() - interval '2 days 10 hours', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS week,
         to_char(now() - interval '22 days 4 hours', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS month,
         to_char(now() - interval '2 days 10 hours 14 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS key_week,
         to_char(now() - interval '11 days 20 hours', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS key_month
), budgets AS (
  SELECT '{"chaos-fast":{"value_budget":2000000000000000},"chaos-slow":{"value_budget":3000000000000000},"chaos-free":{}}'::jsonb AS models
)
UPDATE providers p SET
  billing_mode = 'subscription',
  subscription_plan = jsonb_build_object('label', 'Bench plan', 'constraints', jsonb_build_array(
    jsonb_build_object('kind', 'rolling_window', 'label', '5h', 'duration', '5h0m0s',
      'value_budget', 1000000000000000, 'scope', 'shared', 'model_budgets', b.models, 'window_anchor', a.h5),
    jsonb_build_object('kind', 'rolling_window', 'label', 'Semaine', 'duration', '168h0m0s',
      'value_budget', 1000000000000000, 'scope', 'shared', 'model_budgets', b.models,
      'reserve_ratio', 0.1, 'share_threshold', 0.8, 'window_anchor', a.week),
    jsonb_build_object('kind', 'rolling_window', 'label', 'Mois', 'duration', '720h0m0s',
      'value_budget', 1000000000000000, 'scope', 'shared', 'model_budgets', b.models,
      'share_threshold', 0.7, 'window_anchor', a.month)
  ))::text,
  api_keys = jsonb_build_array(jsonb_build_object(
    'id', p.id || '-key2', 'label', 'Second key', 'api_key', p.api_key,
    'overrides', jsonb_build_object(
      'Semaine', jsonb_build_object('window_anchor', a.key_week),
      'Mois', jsonb_build_object('window_anchor', a.key_month))
  ))::text
FROM anchors a, budgets b
WHERE p.id IN ('prov-chaos', 'prov-chaos-globex');

-- History: every chaos record, plan-covered, spread evenly over 30 days and
-- over the two keys.
UPDATE usage_records SET
  plan_covered = 1,
  created_at = now() - interval '30 days' * random() - interval '1 hour',
  provider_key_id = CASE WHEN random() < 0.5 THEN '' ELSE provider_id || '-key2' END
WHERE provider_id IN ('prov-chaos', 'prov-chaos-globex');

DELETE FROM plan_usage_hourly;
INSERT INTO plan_usage_hourly (org_id, provider_id, hour, provider_key_id, model_id, user_id, requests, total_tokens, provider_cost)
SELECT org_id, provider_id, to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24'), COALESCE(provider_key_id, ''), model_id, COALESCE(user_id, ''),
       COUNT(*), COALESCE(SUM(total_tokens), 0), COALESCE(SUM(provider_cost), 0)
  FROM usage_records
 WHERE plan_covered = 1
 GROUP BY 1, 2, 3, 4, 5, 6;

-- The per-minute sums of xolo#234, on the releases that have them.
DO $$
BEGIN
  IF to_regclass('plan_usage_minutely') IS NOT NULL THEN
    DELETE FROM plan_usage_minutely;
    INSERT INTO plan_usage_minutely (org_id, provider_id, minute, provider_key_id, model_id, user_id, requests, total_tokens, provider_cost)
    SELECT org_id, provider_id, to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI'), COALESCE(provider_key_id, ''), model_id, COALESCE(user_id, ''),
           COUNT(*), COALESCE(SUM(total_tokens), 0), COALESCE(SUM(provider_cost), 0)
      FROM usage_records
     WHERE plan_covered = 1
     GROUP BY 1, 2, 3, 4, 5, 6;
  END IF;
END $$;

COMMIT;
ANALYZE usage_records;
ANALYZE plan_usage_hourly;
