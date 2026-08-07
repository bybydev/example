# Multimodal Attachments

BYOKchat supports image and file attachments as part of persisted user messages.

## Composer

The chat composer can attach:

- images from the photo library
- files from the system document picker
- attachment-only messages without typed text

Selected images are normalized to JPEG before persistence and provider submission. This avoids HEIC and other source-format compatibility differences across OpenAI-compatible providers.

Current limits are:

- up to 8 attachments per message
- up to 20 MiB per attachment
- up to 40 MiB total attachment data per message

Attachments can be removed from the composer before sending.

## Conversation persistence

Attachments are stored directly on the user `ChatMessage` as Codable data. This means they survive:

- app relaunch
- normal conversation persistence
- regeneration
- edit-and-resend history truncation
- full backup and restore

Attachment filenames also participate in local conversation search.

The initial implementation intentionally keeps the attachment data model simple. It does not yet deduplicate large binary data into a separate blob store.

## Provider request encoding

`ProviderMessage` carries the persisted attachment records into the provider runtime.

For OpenAI-compatible Chat Completions requests:

- image attachments are encoded as `image_url` content parts using base64 data URLs
- UTF-8 text-like files are converted into text content parts with the filename and file contents
- other binary files are encoded as `file` content parts with a filename and base64 data URL

Messages without attachments continue to use normal string `content`, preserving compatibility with text-only providers.

Text-like file inlining makes common source code, Markdown, JSON, configuration, and plain-text files usable with OpenAI-compatible endpoints even when the endpoint has no native file-upload API.

Binary `file` content parts depend on provider support. OpenRouter supports file inputs, including PDFs. Other custom OpenAI-compatible endpoints may reject file content parts; BYOKchat surfaces the provider error rather than silently dropping the attachment.

## Context management

Attachment-bearing user messages participate in normal conversation context selection.

Token estimation uses:

- the actual UTF-8 text size for text-like files
- a conservative fixed estimate for images
- a conservative fixed estimate for other binary files

Binary multimodal tokenization varies substantially by model and provider, so the local estimate is deliberately approximate.

## UI

Persisted user messages display their attachments in the timeline:

- images render as thumbnails
- files render as filename and size cards

The composer shows the same attachment strip with removal controls before sending.

## Security and privacy

Attachment bytes stay in local BYOKchat conversation storage until the user sends the message. When sent, they are transmitted directly from the device to the selected BYOK provider endpoint as part of the model request.

BYOKchat does not operate a proxy or attachment server.

Because full backups contain conversation data, they also contain persisted attachment bytes. API credentials remain excluded from backups.

## Remaining work

Useful follow-up work includes:

- provider/model capability warnings before sending unsupported modalities
- native upload/file-ID APIs where they provide a clear benefit
- attachment deduplication or external blob storage for very large histories
- richer previews for PDFs and documents
- attachment metadata in Markdown conversation export
- drag/drop and pasteboard attachment intake
- provider-specific image detail controls
