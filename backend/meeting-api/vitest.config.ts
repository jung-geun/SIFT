import { configDefaults, defineConfig } from 'vitest/config';

// Unit suite (`npm test`, CI, Cloud Build). test/integration/** is the separate
// integration suite (vitest.integration.config.ts) and must not run here.
export default defineConfig({
  test: {
    environment: 'node',
    include: ['test/**/*.test.ts'],
    exclude: [...configDefaults.exclude, 'test/integration/**']
  }
});
