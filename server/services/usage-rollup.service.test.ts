import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { usageRollupService } from '@/services/usage-rollup.service.js';

async function writeJsonl(filePath: string, lines: object[]): Promise<void> {
  await fs.writeFile(filePath, lines.map(o => JSON.stringify(o)).join('\n') + '\n');
}

test('summarize: 5h includes only recent entries; week includes recent+middle; older is excluded', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'usage-rollup-'));
  try {
    const projDir = path.join(tmp, '-Users-test-proj');
    await fs.mkdir(projDir, { recursive: true });

    const now = Date.now();
    const tsIn5h = new Date(now - 1 * 60 * 60 * 1000).toISOString();        // 1h ago — in both windows
    const tsInWeek = new Date(now - 3 * 24 * 60 * 60 * 1000).toISOString(); // 3d ago — week only
    const tsOld = new Date(now - 8 * 24 * 60 * 60 * 1000).toISOString();    // 8d ago — excluded

    const model = 'claude-opus-4-7[1m]';

    await writeJsonl(path.join(projDir, 'sess1.jsonl'), [
      {
        type: 'assistant',
        timestamp: tsIn5h,
        message: {
          model,
          usage: {
            input_tokens: 1000,
            output_tokens: 500,
            cache_creation_input_tokens: 200,
            cache_read_input_tokens: 100,
          },
        },
      },
      {
        type: 'assistant',
        timestamp: tsInWeek,
        message: {
          model,
          usage: {
            input_tokens: 2000,
            output_tokens: 1000,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
          },
        },
      },
      {
        type: 'assistant',
        timestamp: tsOld,
        message: {
          model,
          usage: {
            input_tokens: 99999,
            output_tokens: 99999,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
          },
        },
      },
    ]);

    const result = await usageRollupService.summarize(tmp, now);

    // 5h window: only the 1h-ago entry (1000+500+200+100 = 1800)
    assert.equal(result.fiveHour.input, 1000);
    assert.equal(result.fiveHour.output, 500);
    assert.equal(result.fiveHour.cacheCreation, 200);
    assert.equal(result.fiveHour.cacheRead, 100);
    assert.equal(result.fiveHour.total, 1800);
    assert.ok(result.fiveHour.costUsd > 0, 'fiveHour costUsd should be positive for opus pricing');

    // week window: 1h-ago + 3d-ago = (1000+2000)+(500+1000)+(200+0)+(100+0) = 4800
    assert.equal(result.week.input, 3000);
    assert.equal(result.week.output, 1500);
    assert.equal(result.week.cacheCreation, 200);
    assert.equal(result.week.cacheRead, 100);
    assert.equal(result.week.total, 4800);
    assert.ok(result.week.costUsd > result.fiveHour.costUsd);

    // byModel keyed by the model string
    assert.ok(model in result.fiveHour.byModel, 'fiveHour.byModel should have model key');
    assert.equal(result.fiveHour.byModel[model].input, 1000);
    assert.ok(result.fiveHour.byModel[model].costUsd > 0);

    assert.ok(result.asOf > 0);
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test('summarize: returns zero totals for empty directory', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'usage-rollup-empty-'));
  try {
    const result = await usageRollupService.summarize(tmp, Date.now());
    assert.equal(result.fiveHour.total, 0);
    assert.equal(result.week.total, 0);
    assert.equal(result.fiveHour.costUsd, 0);
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});

test('summarize: skips files whose mtime predates the week cutoff', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'usage-rollup-stale-'));
  try {
    const projDir = path.join(tmp, 'proj');
    await fs.mkdir(projDir);
    const filePath = path.join(projDir, 'stale.jsonl');

    const now = Date.now();
    const oldTs = new Date(now - 8 * 24 * 60 * 60 * 1000).toISOString();
    await writeJsonl(filePath, [
      {
        type: 'assistant',
        timestamp: oldTs,
        message: { model: 'claude-sonnet', usage: { input_tokens: 5000, output_tokens: 2000 } },
      },
    ]);
    // Set mtime to 8 days ago so the stat-level skip triggers.
    const oldDate = new Date(now - 8 * 24 * 60 * 60 * 1000);
    await fs.utimes(filePath, oldDate, oldDate);

    const result = await usageRollupService.summarize(tmp, now);
    assert.equal(result.week.total, 0, 'Stale file should be skipped at stat level');
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
});
