import { z } from 'zod';

const ProviderConfigEntrySchema = z.object({
  provider: z.enum(['openAI', 'google']),
  enabled: z.boolean(),
  endpointClasses: z.array(z.string()),
  documentationURLs: z.array(z.string().url()),
  reviewedAt: z.string(),
  processingRegion: z.string(),
  paidTier: z.boolean(),
  categoriesSent: z.array(z.string()),
  appTemporaryRetentionHours: z.number().int().nonnegative(),
  providerRetentionStatementKey: z.string(),
  trainingLoggingStatementKey: z.string(),
  termsURL: z.string().url(),
}).strict();

export const ProviderConfigSchema = z.object({
  configurationVersion: z.string().min(1),
  keyID: z.string().min(1),
  issuedAt: z.string(),
  expiresAt: z.string(),
  providers: z.array(ProviderConfigEntrySchema),
  signature: z.string().min(1),
}).strict();

export type ProviderConfig = z.infer<typeof ProviderConfigSchema>;

export const defaultProviderConfig: ProviderConfig = {
  configurationVersion: 'local-disabled-1',
  keyID: 'local',
  issuedAt: new Date(0).toISOString(),
  expiresAt: new Date(0).toISOString(),
  providers: [
    { provider: 'openAI', enabled: false, endpointClasses: [], documentationURLs: [], reviewedAt: new Date(0).toISOString(), processingRegion: 'unknown', paidTier: true, categoriesSent: [], appTemporaryRetentionHours: 0, providerRetentionStatementKey: 'disabled', trainingLoggingStatementKey: 'disabled', termsURL: 'https://openai.com/policies/terms-of-use' },
    { provider: 'google', enabled: false, endpointClasses: [], documentationURLs: [], reviewedAt: new Date(0).toISOString(), processingRegion: 'unknown', paidTier: true, categoriesSent: [], appTemporaryRetentionHours: 0, providerRetentionStatementKey: 'disabled', trainingLoggingStatementKey: 'disabled', termsURL: 'https://ai.google.dev/gemini-api/terms' },
  ],
  signature: 'disabled',
};

export function providerIsEnabled(config: ProviderConfig, provider: 'openAI' | 'google'): boolean {
  const entry = config.providers.find(item => item.provider === provider);
  if (!entry || !entry.enabled) return false;
  const expiry = Date.parse(config.expiresAt);
  const issued = Date.parse(config.issuedAt);
  const now = Date.now();
  return Number.isFinite(issued) && Number.isFinite(expiry) && issued <= now && now < expiry;
}
