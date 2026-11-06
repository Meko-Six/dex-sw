// The original audit's unsafe-behavior probes have become permanent regressions.
// Historical observations remain in out/project-review/ and the review document.
import { execFileSync } from 'node:child_process'
import path from 'node:path'
execFileSync(process.execPath, [path.resolve('node_modules/vitest/vitest.mjs'), 'run',
  'tests/deck-loading.test.ts', 'tests/audio-jobs.test.ts', 'tests/audio-lifecycle.test.ts',
  'tests/library-repository.test.ts', 'tests/browser-files.test.ts', 'tests/runtime-security.test.ts', 'tests/transcode.test.ts'
], { stdio: 'inherit' })
console.log('For production Electron integration: npm run build && npm run check:runtime')
console.log('For the two-track memory/render profile (local accuracy files): npm run check:resources')
