# Pro locking and AppFoundation themes

## Authorization

The user approved four Pro benefits, monthly $6.99, lifetime $24.99, and explicitly requested implementation. This supersedes P5's Pro deferral. Implement V1.PRO and access rules on existing V1.LOCAL_STT/JOB/STYLE/PRESETS/MP4; do not reopen retired features. One PR from latest develop (eb89f0f), feat/ios-pro-access-themes → develop, held open for review.

| Capability | Free | Pro |
|---|---|---|
| Captioning | 5 minutes/week | Unlimited |
| Caption styling | Basic Modern font, no animation; color/size/outline/background/position | All existing fonts, four templates and animations |
| New MP4 export | 720p | 720p/1080p |
| App appearance | AF default Rose theme | All AF premium themes |
| Import/projects, text/timing editing, split/merge/undo, trim/crop/volume, SRT | Included | Included |

Products: com.hoangbkit.inkribe.pro.monthly and com.hoangbkit.inkribe.pro.lifetime. No yearly product, watermark, trial, consumable credits or backend.

## Implementation contract

- Use pinned AppFoundation 1.6.4 (PR #34 settings follow-up) purchase lifecycle, verified entitlements, ProPaywallView, LimitReachedUpsellFlow and ThemePickerView. Keep iOS persistence isolated. Live prices come from StoreKit; the approved USD prices configure only the local iOS StoreKit file and opt-in Debug simulator in source.
- Central access gates must run before new work or style mutation. Contextual locked actions show the AF comparison/upsell before its paywall. Projects has explicit Pro and Appearance entries; plan view shows usage, restore and subscription management.
- Reserve canonical audio-bearing clip duration, rounded up to whole seconds per job. Reset Monday 00:00 UTC. Trim/context decode windows do not change the quota calculation. Durable reservation before queue publication; charge successful document publication only; release failed/cancelled/orphan reservations. Reconciliation handles interruption between project publication and usage write without double charging. Local enforcement has no server/device-clock tamper protection.
- Preserve accepted jobs, saved premium styles, editable captions, original media and retained export delivery after expiry. New premium font/effect/1080p/theme choices require Pro. No destructive style migration. Pre-policy jobs remain supported.
- Apply AF theme tokens to app surfaces, tint, cards/timeline selection and appearance. Keep footage/caption rendering independent. Theme previews are disabled; no invented trial.

## Evidence and remaining inputs

Source integrated; read handoffs/PRO.md. No compile/build/typecheck/test, CI, project generation, weights, runtime export or device/UI verification. PR #34 adds Spokio-style Settings and Debug AF Developer Tools, retaining existing product IDs/prices and access rules. Actual App Store Connect product availability/pricing and replacing the user-requested dummy privacy URL remain release inputs. Preserve Mac/catalog and keep PR open until asked to merge.
