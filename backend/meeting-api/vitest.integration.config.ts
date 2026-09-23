import { defineConfig } from 'vitest/config';

// Integration suite (`npm run test:integration`). Standalone on purpose:
// mergeConfig() concatenates arrays, so merging the unit config would inherit
// its test/integration/** exclude and its unit-test include.
export default defineConfig({
  test: {
    environment: 'node',
    include: ['test/integration/**/*.test.ts'],
    testTimeout: 120_000
  }
});
