# Model capability resolution

Issue #32 is implemented in `BYOKchatProviderCore`. Both iOS and macOS use the
same resolver for account/model selection, composer labels, and effective
request options. Provider adapters retain their own wire formats.

## Evidence and compatibility

`ProviderModel.capabilityEvidence` is optional. Existing workspaces and exports
decode without it; no schema bump or conversation rewrite is required. Legacy
modality/parameter sets provide positive hints, never exhaustive negatives.

Each fact resolves independently, in this order:

1. Explicit discovery
2. Verified native/adapter contract
3. Curated seed catalog
4. Inference
5. Unknown

New observations replace equally authoritative old observations. Missing fields
retain fallback evidence. Explicit negatives survive seed and workspace merges.
Numeric limits preserve their provenance and input-only versus combined context
window semantics. Values synthesized inside discovery remain inference.

OpenRouter's present parameter and architecture lists are interpreted as
exhaustive. Custom-compatible catalogs using those field names supply positive
hints; their omissions do not prove non-support. Anthropic preserves missing
capability objects separately from `supported: false`. xAI language modalities
do not describe its separate Files route.

Adapter route limits are hard boundaries on effective request support. The
current adapters handle text/tool output, not image/audio generation. Raw audio
input is only encoded by the Gemini inline-data route. Model evidence remains
stored separately from these effective constraints.

## Reasoning selections

`nil` means **Default**, which omits reasoning configuration. It is never migrated
to explicit Off. **Off** is offered only when the selected model has a real
disable instruction. Minimal/Low remain distinct from Off, and Extra High
(`xhigh`) remains distinct from Max.

Native rules are API-scoped. For example, mandatory Grok reasoning cannot be
turned off; Gemini 2.5 uses token budgets while Gemini 3 uses thinking levels;
older Claude thinking uses `enabled` plus `budget_tokens` rather than adaptive
thinking. Opus 4.5 can combine effort with a thinking budget. Other implemented
effort and budget controls are alternatives.

Budgets validate minimum/maximum bounds. Gemini automatic budgeting preserves
`-1`; explicit Off sends `0` where allowed. Anthropic thinking budgets must be
below the actual output limit, including its 4,096-token application default.

Valid staged selections survive a target change. Invalid selections resolve to
provider Default and are displayed before Done. Metadata changes reconcile
staged options. Done commits atomically; Cancel discards them. Opening an old
conversation does not persist normalized options. Unrelated request options and
applicable reasoning visibility settings remain intact.

Unknown routed/custom controls do not get a guessed effort ladder. Without
verified control metadata, routed reasoning uses provider Default. Generic
custom and NVIDIA adapters do not inject speculative reasoning parameters.
Ordinary text chat remains available. Additional native rules belong in
`ModelCapabilityResolver.reasoningControl`, not in either picker.

## Request preparation

`ChatRuntime` resolves one account-scoped snapshot per turn, including hidden
selected models. Unsupported tool definitions and incompatible history are
projected before context estimation. `ProviderRuntime` applies the same policy
to streaming and non-streaming calls; direct adapter requests also prepare it.

Text attachments serialized as text require text support rather than file
support. Both Responses adapters now use text parts for UTF-8 text attachments;
xAI uploads only non-text files. Format and attachment size limits apply in
addition to model support. Unknown support permits a deliberate attempt when
the adapter can encode the input.

Unsupported current-turn attachments produce an actionable error. Earlier
incompatible attachments become textual omission notes in the request. Tool
calls/results for a model with verified unsupported tools become labelled text,
and incompatible continuation payloads are removed. These projections do not
modify saved messages, attachment bytes, or MCP selections. Existing provider
continuation ownership checks still apply.

## Contract references

Native control rules were reviewed against official documentation on 2026-10-05:

- [OpenAI reasoning](https://developers.openai.com/api/docs/guides/reasoning)
- [Anthropic effort](https://platform.claude.com/docs/en/build-with-claude/effort)
- [Anthropic thinking](https://platform.claude.com/docs/en/build-with-claude/thinking)
- [Gemini generateContent ThinkingConfig](https://ai.google.dev/api/generate-content#ThinkingConfig)
- [Gemini thinking levels](https://ai.google.dev/gemini-api/docs/thinking)
- [Gemini 2.5 thinking budgets](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/thinking)
- [xAI reasoning](https://docs.x.ai/developers/model-capabilities/text/reasoning)
- [DeepSeek thinking](https://api-docs.deepseek.com/guides/thinking_mode/)

Gemini Interactions field names are not used by the generateContent adapter.
The current DeepSeek alias contract includes Low; older V4 rules retain the
existing High/Max contract pending a version-specific guarantee for Low.

## Validation status

Regression tests cover evidence precedence and persistence, staged reasoning
semantics, budget bounds and combinations, native wire contracts, request-only
history projection, and filtering tools before context budgeting. Existing
expectations for xAI's former Max-to-Extra-High remapping and platform labels
were updated to the new semantics.

Tests and platform builds have not been run. Execution is pending the user's
requested approval before testing.
