# ReadAloud Privacy

ReadAloud is designed as a local-first, on-device reading and speech application.

## Data collection

ReadAloud 1.0 does not collect personal data, track users across apps or websites, or send document contents to a remote speech service.

Imported documents, normalized text, generated audio, reading progress, narration settings, and caches are stored locally on the user's device.

Purchase and subscription processing is handled by Apple through StoreKit. ReadAloud uses AppFoundation to read verified entitlement state and does not maintain a separate production entitlement account.

## Analytics

Analytics integration hooks may exist in the app architecture, but analytics is disabled by default in ReadAloud 1.0. When disabled, ReadAloud does not create an analytics installation identifier, event queue, or analytics network traffic.

## Support

For support, use the ReadAloud GitHub issue tracker linked from the app's Settings screen.
