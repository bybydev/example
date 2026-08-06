# ProviderCore Origin

BYOKchat's provider core was started from the concepts and direct-provider implementation in `hoangbkit/AppFoundation` version `1.2.0`.

The source was intentionally detached and independently rewritten for BYOKchat. It is not kept source-compatible with AppFoundation and it does not use AppFoundation's AI backend manager, managed proxy client, App Attest, entitlement, quota, or provider-configuration UI.

The first independent implementation concentrates on the OpenAI-compatible protocol family and first-class behavior for:

- DeepSeek
- OpenRouter
- NVIDIA hosted NIM APIs

BYOKchat owns all changes from this point forward.
