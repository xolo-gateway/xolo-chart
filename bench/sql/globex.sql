-- Gives the second organization of the fixture the chaos provider and its
-- fast model, so a campaign can spread its load over two organizations:
-- the budget counters of one organization are rows every one of its
-- requests updates, and one organization alone caps the measure (xolo#223).
DELETE FROM llm_models WHERE id = 'mdl-chaos-fast-globex';
DELETE FROM providers WHERE id = 'prov-chaos-globex';
INSERT INTO providers
  (id, created_at, updated_at, org_id, name, type, base_url, api_key, active,
   currency, cloud_tier, retry_config, rate_limit_config, billing_mode, subscription_plan)
SELECT 'prov-chaos-globex', now(), now(), o.id, p.name, p.type, p.base_url, p.api_key, p.active,
       p.currency, p.cloud_tier, p.retry_config, p.rate_limit_config, p.billing_mode, p.subscription_plan
  FROM providers p, organizations o WHERE p.id = 'prov-chaos' AND o.slug = 'globex';
INSERT INTO llm_models
  (id, created_at, updated_at, provider_id, org_id, proxy_name, real_model, description, enabled,
   prompt_cost_per1_k_tokens, completion_cost_per1_k_tokens,
   context_window, output_window, active_params, tokens_per_sec_low, tokens_per_sec_high)
SELECT 'mdl-chaos-fast-globex', now(), now(), 'prov-chaos-globex', o.id, 'chaos-fast', 'chaos-fast',
       'Ligne de base : reponse immediate.', 1, 100, 200, 32000, 4096, 8000000000, 200, 400
  FROM organizations o WHERE o.slug = 'globex';
-- The organization's daily budget is zero in the fixture, and reaches its
-- members: no budget at all for the campaign.
UPDATE quota SET daily_budget = NULL, monthly_budget = NULL, yearly_budget = NULL
 WHERE scope = 'org' AND scope_id IN (SELECT id FROM organizations WHERE slug = 'globex');
-- Erin's own budget is zero in the fixture: a multiplier leaves it so.
DELETE FROM quota WHERE scope = 'user' AND scope_id IN (SELECT id FROM users WHERE email = 'erin@globex.test');
