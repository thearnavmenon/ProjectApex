// Project Apex — ADR-0007 retry-and-surface policy in TypeScript.
//
// Per ADR-0007 §"Retry shape (transient errors only)":
//   - 3 retries (4 total attempts)
//   - base delay 1s doubling each attempt (1s → 2s → 4s)
//   - random jitter up to 0.5s
//   - cooperative (no Task.checkCancellation equivalent in Deno; AbortSignal)
//   - permanent errors throw immediately, do NOT consume retries
//
// This is the canonical TS implementation of the policy. Future LLM-driven
// slices (coach-tone classifier, digest summarizer, anything else) inherit
// the retry semantic by importing `withLLMRetry` from this module rather
// than re-implementing it inline. ADR-0007 has one source-of-truth in code.
//
// Slice A13 (note-classifier) is the first consumer.
//
// The retry budget is bounded — total worst-case retry duration ~7s + jitter
// — small enough to fit inside a Supabase Edge Function's invocation
// timeout when called from Stage 2 (which itself doesn't gate the HTTP
// response per ADR-0013).

/**
 * Errors classified as transient per ADR-0007's §1 table:
 *   HTTP 429 / 502 / 503 / 504 / 529 (Anthropic overload)
 *   Network errors: notConnectedToInternet, networkConnectionLost,
 *                   timedOut, cannotConnectToHost, dnsLookupFailed
 *
 * Other errors (HTTP 4xx other than 429, malformed response, empty
 * response, anything else) are permanent and throw immediately.
 */
export class LLMTransientError extends Error {
  constructor(message: string, public readonly originalError?: unknown) {
    super(message);
    this.name = "LLMTransientError";
  }
}

export class LLMPermanentError extends Error {
  constructor(
    message: string,
    public readonly errorClass: string,
    public readonly originalError?: unknown,
  ) {
    super(message);
    this.name = "LLMPermanentError";
  }
}

/**
 * Classify an HTTP status as transient or permanent per ADR-0007.
 * Returns null for 2xx statuses (caller should use the response body).
 */
export function classifyHttpStatus(
  status: number,
): "transient" | "permanent" | null {
  if (status >= 200 && status < 300) return null;
  if (status === 429 || status === 502 || status === 503 || status === 504 || status === 529) {
    return "transient";
  }
  return "permanent";
}

const RETRY_DELAYS_MS = [1000, 2000, 4000] as const;
const JITTER_MAX_MS = 500;

/**
 * Bounded exponential backoff per ADR-0007. Calls `op` up to 4 times total
 * (initial + 3 retries). On `LLMTransientError`, sleeps with jittered
 * exponential backoff before retrying. On `LLMPermanentError`, throws
 * immediately without consuming retries. On retry exhaustion, throws the
 * last `LLMTransientError`.
 *
 * Tests can inject `deps.sleep` to bypass real timers.
 */
export async function withLLMRetry<T>(
  op: () => Promise<T>,
  deps: { sleep?: (ms: number) => Promise<void> } = {},
): Promise<T> {
  const sleep = deps.sleep ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
  let lastTransient: LLMTransientError | null = null;
  for (let attempt = 0; attempt <= RETRY_DELAYS_MS.length; attempt++) {
    try {
      return await op();
    } catch (err) {
      if (err instanceof LLMPermanentError) {
        // Permanent: throw immediately, do not consume retries.
        throw err;
      }
      if (err instanceof LLMTransientError) {
        lastTransient = err;
        if (attempt < RETRY_DELAYS_MS.length) {
          const baseDelay = RETRY_DELAYS_MS[attempt];
          const jitter = Math.random() * JITTER_MAX_MS;
          await sleep(baseDelay + jitter);
          continue;
        }
        // Retries exhausted; fall through to throw below.
        break;
      }
      // Non-LLM error class: treat as permanent (defensive — caller should
      // wrap unknown errors as LLMPermanentError before they reach here).
      throw new LLMPermanentError(
        `unexpected error: ${err instanceof Error ? err.message : String(err)}`,
        "unexpected_error",
        err,
      );
    }
  }
  // Loop only exits via `throw` (permanent) or `return` (success) — except
  // when retries exhaust on the last transient attempt. lastTransient is
  // guaranteed non-null here.
  throw lastTransient!;
}
