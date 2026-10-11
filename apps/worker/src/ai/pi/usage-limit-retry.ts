// Copyright (C) 2025 Keygraph, Inc.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License version 3
// as published by the Free Software Foundation.

import timers from 'node:timers/promises';
import type { StreamFn } from '@earendil-works/pi-agent-core';
import {
  type Api,
  type AssistantMessageEvent,
  createAssistantMessageEventStream,
  isRetryableAssistantError,
  type Model,
} from '@earendil-works/pi-ai';

/** pi's Codex transport converts subscription reset timestamps to this message. */
export function chatGptUsageRetryDelay(message: string): number | undefined {
  if (!/you have hit your ChatGPT usage limit|usage_limit_reached/i.test(message)) return undefined;
  const minutes = /try again in ~?(\d+(?:\.\d+)?) min/i.exec(message)?.[1];
  // The provider rounds reset times to minutes. Add a minute to avoid retrying early.
  return minutes === undefined ? 60_000 : Math.max(60_000, (Number(minutes) + 1) * 60_000);
}

/** z.ai can be selected directly or through its Anthropic-compatible gateway. */
export function isZaiModel(model: Model<Api>): boolean {
  if (model.provider === 'zai' || model.provider === 'zai-coding-cn') return true;
  try {
    const host = new URL(model.baseUrl).hostname.toLowerCase();
    return host === 'z.ai' || host.endsWith('.z.ai') || host === 'bigmodel.cn' || host.endsWith('.bigmodel.cn');
  } catch {
    return false;
  }
}

/** Resettable Coding Plan limits must survive the generic quota classifier. */
export function zaiUsageRetryDelay(message: string, now = Date.now()): number | undefined {
  // See https://docs.z.ai/api-reference/api-code. Some resettable limits also
  // mention insufficient balance for extra usage; they still recover at reset.
  const usageLimit =
    /\b(?:1308|1310|131[6-9]|132[01])\b|usage limit reached|(?:weekly|monthly)[/\s]*(?:monthly)? limit exhausted/i.test(
      message,
    );
  if (!usageLimit) {
    // These 429s require an account change rather than a usage-window reset.
    if (
      /\b(?:1113|1309|1311|1313|1314|1315)\b|insufficient[_ ]quota|insufficient balance|recharge|expired|not.+include access|billing|out of budget/i.test(
        message,
      )
    ) {
      return undefined;
    }
    if (!/\b429\b|rate.?limit|too many requests/i.test(message)) return undefined;
  }
  const reset = /(?:resets? at|reset at)\s*[`"']?([^`"'\n}]+)/i.exec(message)?.[1]?.trim();
  if (reset) {
    let timestamp = Number.NaN;
    if (/^\d{10}(?:\d{3})?$/.test(reset)) {
      timestamp = Number(reset) * (reset.length === 10 ? 1000 : 1);
    } else if (/(?:Z|[+-]\d{2}:?\d{2})\.?$/i.test(reset)) {
      // Dates without a timezone are ambiguous; poll instead of guessing.
      timestamp = Date.parse(reset.replace(/\.$/, ''));
    }
    if (Number.isFinite(timestamp)) return Math.max(60_000, timestamp - now + 1000);
  }
  return 60_000;
}

/** Retry the same request without ending the agent turn or losing its context. */
export function withUsageLimitRetries(streamFn: StreamFn, cancellationSignal?: AbortSignal): StreamFn {
  return (model, context, options) => {
    const zai = isZaiModel(model);
    if (model.provider !== 'openai-codex' && !zai) return streamFn(model, context, options);
    if (cancellationSignal) {
      options = {
        ...options,
        signal: options?.signal ? AbortSignal.any([options.signal, cancellationSignal]) : cancellationSignal,
      };
    }
    const output = createAssistantMessageEventStream();
    void (async () => {
      let lastError: Extract<AssistantMessageEvent, { type: 'error' }> | undefined;
      try {
        let transientRetries = 0;
        for (;;) {
          let retryAfterMs: number | undefined;
          const input = await streamFn(model, context, {
            ...options,
            // Let this layer see usage errors before transport retries or delay caps consume them.
            maxRetries: 0,
            onResponse: async (response, responseModel) => {
              const headers = new Headers(response.headers);
              const millis = headers.get('retry-after-ms');
              const retryAfter = headers.get('retry-after');
              if (millis !== null && Number.isFinite(Number(millis))) retryAfterMs = Number(millis);
              else if (retryAfter !== null) {
                retryAfterMs = Number.isFinite(Number(retryAfter))
                  ? Number(retryAfter) * 1000
                  : Date.parse(retryAfter) - Date.now();
              }
              await options?.onResponse?.(response, responseModel);
            },
          });
          // Hold the start event until we know this attempt produced content.
          // Failed attempts must not add extra assistant messages to the transcript.
          const pending: AssistantMessageEvent[] = [];
          let emittedContent = false;
          let delayMs: number | undefined;
          for await (const event of input) {
            if (event.type === 'start') {
              pending.push(event);
              continue;
            }
            if (event.type === 'error' && event.error.stopReason === 'error' && !emittedContent) {
              lastError = event;
              delayMs = zai
                ? zaiUsageRetryDelay(event.error.errorMessage ?? '')
                : chatGptUsageRetryDelay(event.error.errorMessage ?? '');
              if (delayMs === undefined && transientRetries < 8 && isRetryableAssistantError(event.error)) {
                delayMs = 1000 * 2 ** transientRetries++;
              }
              if (delayMs !== undefined) {
                if (retryAfterMs !== undefined && Number.isFinite(retryAfterMs)) {
                  delayMs = Math.max(delayMs, retryAfterMs);
                }
                break;
              }
            }
            for (const start of pending.splice(0)) output.push(start);
            output.push(event);
            emittedContent = true;
          }
          if (delayMs === undefined) {
            output.end(await input.result());
            return;
          }
          console.warn(
            `[${zai ? 'z.ai' : 'openai-codex'}] ${lastError?.error.errorMessage} Retrying in ${Math.ceil(delayMs / 1000)}s.`,
          );
          // Long reset waits stay cancellable and within Node's timer range.
          let remaining = delayMs;
          while (remaining > 0) {
            const chunk = Math.min(remaining, 60_000);
            await timers.setTimeout(chunk, undefined, options?.signal ? { signal: options.signal } : {});
            remaining -= chunk;
          }
        }
      } catch (error) {
        if (lastError) {
          output.push({
            type: 'error',
            reason: options?.signal?.aborted ? 'aborted' : 'error',
            error: {
              ...lastError.error,
              stopReason: options?.signal?.aborted ? 'aborted' : 'error',
              errorMessage: error instanceof Error ? error.message : String(error),
            },
          });
        } else {
          // Provider stream functions normally encode errors in their stream.
          // Preserve a thrown exception as a terminal assistant error as well.
          output.push({
            type: 'error',
            reason: 'error',
            error: {
              role: 'assistant',
              content: [],
              api: model.api,
              provider: model.provider,
              model: model.id,
              usage: {
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0,
                totalTokens: 0,
                cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
              },
              stopReason: 'error',
              timestamp: Date.now(),
              errorMessage: String(error),
            },
          });
        }
      }
    })();
    return output;
  };
}
