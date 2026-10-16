import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';

// Official API: https://developers.cloudflare.com/api/resources/accounts/subresources/subscriptions/methods/get/
// Official pricing: https://developers.cloudflare.com/workers/platform/pricing/
// Workers defaults to Free without a Workers subscription. Account listings may
// also contain the unrelated Zero Trust Free plan. Recognize only its exact
// zero-cost, non-trial product contract; never accept a name or price alone.
export function assertFreeSubscriptions(body) {
  if (body?.success !== true || !Array.isArray(body.errors) || body.errors.length !== 0
      || !Array.isArray(body.result)
      || body.result_info?.total_count !== body.result.length
      || body.result_info?.count !== body.result.length
      || body.result_info?.next_page === true
      || body.result.some(subscription => subscription?.rate_plan?.id !== 'teams_free'
        || subscription.product?.name !== 'prod_teams' || subscription.price !== 0
        || subscription.currency !== 'USD' || subscription.rate_plan.currency !== 'USD'
        || subscription.trial !== null || subscription.rate_plan.is_contract !== false
        || subscription.rate_plan.externally_managed !== false || subscription.rate_plan.scope !== 'account'
        || !Array.isArray(subscription.component_values) || subscription.component_values.length !== 1
        || subscription.component_values[0]?.name !== 'users' || subscription.component_values[0]?.value !== 50)) {
    throw new Error('Free-only guard refused: account has a paid, unknown, trial or incompletely listed subscription.');
  }
}
export function assertProductionConfig(config, accountID) {
  const allowed = ['$schema', 'name', 'main', 'compatibility_date', 'workers_dev', 'preview_urls', 'observability', 'vars', 'd1_databases', 'triggers', 'account_id'];
  if (!config || Object.keys(config).some(key => !allowed.includes(key))
      || config.name !== 'sift-feedback-api' || config.main !== 'src/index.ts'
      || config.vars?.ENVIRONMENT !== 'production' || !['true', 'false'].includes(config.vars?.INTAKE_ENABLED)
      || Object.keys(config.vars).some(key => !['ENVIRONMENT', 'INTAKE_ENABLED'].includes(key))
      || config.observability?.enabled !== false || config.preview_urls !== false
      || (config.account_id !== undefined && config.account_id !== accountID)
      || !Array.isArray(config.d1_databases) || config.d1_databases.length !== 1
      || config.d1_databases[0].binding !== 'DB'
      || config.d1_databases[0].database_name !== 'sift-feedback'
      || config.d1_databases[0].migrations_dir !== 'migrations'
      || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(config.d1_databases[0].database_id ?? '')
      || Object.keys(config.d1_databases[0]).some(key => !['binding', 'database_name', 'database_id', 'migrations_dir'].includes(key))) {
    throw new Error('Free-only guard refused: production configuration must bind an actual provisioned DB and only approved Workers/D1 resources.');
  }
}
export async function guard(environment = process.env, fetcher = fetch) {
  const accountID = environment.CLOUDFLARE_ACCOUNT_ID;
  const token = environment.CLOUDFLARE_API_TOKEN || environment.CLOUDFLARE_OAUTH_TOKEN;
  if (!/^[0-9a-f]{32}$/.test(accountID ?? '') || !token) throw new Error('Free-only guard requires CLOUDFLARE_ACCOUNT_ID and an API/OAuth token with Billing Read.');
  const source = await readFile(new URL('../wrangler.jsonc', import.meta.url), 'utf8');
  // This repository config intentionally uses only full-line JSONC comments;
  // unfamiliar syntax fails JSON parsing rather than weakening the guard.
  const config = JSON.parse(source.split('\n').filter(line => !line.trimStart().startsWith('//')).join('\n'));
  assertProductionConfig(config, accountID);
  const result = await fetcher(`https://api.cloudflare.com/client/v4/accounts/${accountID}/subscriptions`, {
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
    redirect: 'error', signal: AbortSignal.timeout(15000),
  });
  if (!result.ok) throw new Error('Free-only guard could not verify account billing. Deployment refused.');
  assertFreeSubscriptions(await result.json());
  return accountID;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.slice(2).some(argument => argument !== '--deploy') || process.argv.length > 3) throw new Error('Only --deploy is supported; alternate configuration/deployment flags are refused.');
    const accountID = await guard();
    console.log('Verified: no Workers subscription; only default Free and recognized unrelated zero-cost Free products.');
    if (process.argv[2] === '--deploy') {
      const require = createRequire(import.meta.url);
      const wrangler = resolve(dirname(require.resolve('wrangler/package.json')), 'bin/wrangler.js');
      const result = spawnSync(process.execPath, [wrangler, 'deploy', '--config', 'wrangler.jsonc'], {
        cwd: fileURLToPath(new URL('..', import.meta.url)), stdio: 'inherit',
        env: { ...process.env, CLOUDFLARE_ACCOUNT_ID: accountID },
      });
      if (result.error || result.status !== 0) throw new Error('Wrangler deployment failed.');
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : 'Free-only guard failed closed.');
    process.exitCode = 1;
  }
}
