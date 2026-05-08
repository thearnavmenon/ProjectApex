// Project Apex — ADR-0007 retry helper tests.
//
// `withLLMRetry` implements ADR-0007's bounded exponential backoff with
// jitter. Tests inject a mock `sleep` so the retry-shape pinning runs
// instantly (no real timers).

import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  classifyHttpStatus,
  LLMPermanentError,
  LLMTransientError,
  withLLMRetry,
} from "./llm-retry.ts";

// ─── classifyHttpStatus ─────────────────────────────────────────────────────

Deno.test(
  "ADR-0007: 429/502/503/504/529 classify as transient; 4xx-other / 5xx-other classify as permanent; 2xx returns null",
  () => {
    for (const s of [429, 502, 503, 504, 529]) {
      assertEquals(classifyHttpStatus(s), "transient", `status ${s} must be transient`);
    }
    for (const s of [400, 401, 403, 404, 500, 501]) {
      assertEquals(classifyHttpStatus(s), "permanent", `status ${s} must be permanent`);
    }
    for (const s of [200, 201, 204]) {
      assertEquals(classifyHttpStatus(s), null);
    }
  },
);

// ─── withLLMRetry ───────────────────────────────────────────────────────────

Deno.test(
  "ADR-0007: success on first attempt — no retries, no sleeps",
  async () => {
    const sleeps: number[] = [];
    let attempts = 0;
    const result = await withLLMRetry(
      () => {
        attempts++;
        return Promise.resolve(42);
      },
      { sleep: (ms) => Promise.resolve(sleeps.push(ms)) as unknown as Promise<void> },
    );
    assertEquals(result, 42);
    assertEquals(attempts, 1);
    assertEquals(sleeps.length, 0, "no retries needed → no sleeps");
  },
);

Deno.test(
  "ADR-0007: transient error retries up to 3 times with 1s/2s/4s base delays + jitter; succeeds on attempt 4",
  async () => {
    const sleeps: number[] = [];
    let attempts = 0;
    const result = await withLLMRetry(
      () => {
        attempts++;
        if (attempts < 4) throw new LLMTransientError(`transient ${attempts}`);
        return Promise.resolve("ok");
      },
      { sleep: (ms) => Promise.resolve(sleeps.push(ms)) as unknown as Promise<void> },
    );
    assertEquals(result, "ok");
    assertEquals(attempts, 4, "initial + 3 retries");
    assertEquals(sleeps.length, 3, "3 sleeps between 4 attempts");
    // Each sleep is base-delay + jitter [0, 500). Pin the base delays.
    assertEquals(sleeps[0] >= 1000 && sleeps[0] < 1500, true, `attempt-1 retry: 1s base + jitter; got ${sleeps[0]}`);
    assertEquals(sleeps[1] >= 2000 && sleeps[1] < 2500, true, `attempt-2 retry: 2s base + jitter; got ${sleeps[1]}`);
    assertEquals(sleeps[2] >= 4000 && sleeps[2] < 4500, true, `attempt-3 retry: 4s base + jitter; got ${sleeps[2]}`);
  },
);

Deno.test(
  "ADR-0007: transient error retries 3 times, then throws on exhaustion (4 total attempts; sleeps consumed = 3)",
  async () => {
    const sleeps: number[] = [];
    let attempts = 0;
    await assertRejects(
      () =>
        withLLMRetry(
          () => {
            attempts++;
            return Promise.reject(new LLMTransientError(`transient ${attempts}`));
          },
          { sleep: (ms) => Promise.resolve(sleeps.push(ms)) as unknown as Promise<void> },
        ),
      LLMTransientError,
    );
    assertEquals(attempts, 4, "ADR-0007: 4 total attempts (initial + 3 retries)");
    assertEquals(sleeps.length, 3, "3 sleeps between attempts");
  },
);

Deno.test(
  "ADR-0007: permanent error throws immediately on first occurrence — does NOT consume retries",
  async () => {
    const sleeps: number[] = [];
    let attempts = 0;
    await assertRejects(
      () =>
        withLLMRetry(
          () => {
            attempts++;
            return Promise.reject(new LLMPermanentError("malformed", "malformed_response"));
          },
          { sleep: (ms) => Promise.resolve(sleeps.push(ms)) as unknown as Promise<void> },
        ),
      LLMPermanentError,
    );
    assertEquals(attempts, 1, "permanent throws after first attempt; no retries");
    assertEquals(sleeps.length, 0);
  },
);

Deno.test(
  "ADR-0007: 2 transient retries followed by permanent error → throws permanent after attempt 3 (does not exhaust transient budget)",
  async () => {
    const sleeps: number[] = [];
    let attempts = 0;
    await assertRejects(
      () =>
        withLLMRetry(
          () => {
            attempts++;
            if (attempts <= 2) throw new LLMTransientError(`transient ${attempts}`);
            throw new LLMPermanentError("auth failed", "permanent_4xx");
          },
          { sleep: (ms) => Promise.resolve(sleeps.push(ms)) as unknown as Promise<void> },
        ),
      LLMPermanentError,
    );
    assertEquals(attempts, 3, "2 transient retries + 1 permanent attempt");
    assertEquals(sleeps.length, 2, "2 sleeps between transient retries; permanent throws without sleep");
  },
);
