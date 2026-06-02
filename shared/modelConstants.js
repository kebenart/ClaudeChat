/**
 * Centralized Model Definitions
 * Single source of truth for all supported AI models
 */

/**
 * Claude (Anthropic) Models
 *
 * Note: Claude uses two different formats:
 * - SDK format ('sonnet', 'opus') - used by the UI and claude-sdk.js
 * - API format ('claude-sonnet-4.5') - used by slash commands for display
 */
export const CLAUDE_MODELS = {
  // Models in SDK format (what the actual SDK accepts)
  OPTIONS: [
    { value: "opus", label: "Opus" },
    { value: "sonnet", label: "Sonnet" },
    { value: "haiku", label: "Haiku" },
    { value: "claude-opus-4-6", label: "Opus 4.6" },
    { value: "opusplan", label: "Opus Plan" },
    { value: "sonnet[1m]", label: "Sonnet [1M]" },
    { value: "opus[1m]", label: "Opus [1M]" },
  ],

  DEFAULT: "opus",
};

/**
 * Ordered provider registry. Display order in selection UIs.
 */
export const PROVIDERS = [
  { id: "claude", name: "Anthropic", models: CLAUDE_MODELS },
];
