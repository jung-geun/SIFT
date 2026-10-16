import { randomBytes } from 'node:crypto';
import { writeFile } from 'node:fs/promises';

// Creates development-only secrets, never prints or overwrites existing values.
// Wrangler automatically loads this ignored file for the local config.
await writeFile(new URL('../.dev.vars', import.meta.url),
  `ADMIN_TOKEN=${randomBytes(32).toString('hex')}\nNETWORK_HMAC_SECRET=${randomBytes(32).toString('hex')}\n`,
  { flag: 'wx', mode: 0o600 });
console.log('Created private .dev.vars for local development. Do not use these secrets in production.');
