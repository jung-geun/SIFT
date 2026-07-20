import { defineConfig, mergeConfig } from 'vitest/config';
import base from './vitest.config.js';

export default mergeConfig(base, defineConfig({
  test: { include: ['test/integration/**/*.test.ts'], testTimeout: 120_000 }
}));
