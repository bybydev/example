# macOS AI Providers Redesign

## Goal

Bring AI Providers into the same macOS workspace design language as Library, MCP Servers, and Projects:

- flat management home instead of a nested `NavigationSplitView`
- drill into a focused provider workspace
- surface status and defaults before configuration details
- keep model management first-class
- move technical connection settings into a dedicated section
- replace oversized all-in-one forms with smaller, task-focused sheets
- preserve existing provider persistence, Keychain, discovery, testing, and model behaviors

## Navigation model

```text
AI PROVIDERS
     |
     +-- Provider card
     +-- Provider card
     +-- Provider card
            |
            v
     PROVIDER WORKSPACE
            |
            +-- Overview
            +-- Models
            +-- Connection
```

The management surface should not embed its own permanent sidebar. The outer utility sheet already provides the product-level destination context, so provider navigation should be flat and deliberate.

## Providers home

```text
+----------------------------------------------------------------------------+
| AI Providers                                            Search      + Add   |
| Connect the AI services and models you want to use.                       |
+----------------------------------------------------------------------------+
|                                                                            |
|  +--------------------------------+  +--------------------------------+    |
|  | OpenAI                    ...  |  | Anthropic                 ... |    |
|  | Personal                       |  | Claude                         |    |
|  |                                |  |                                |    |
|  | Ready              DEFAULT     |  | Ready                          |    |
|  |                                |  |                                |    |
|  | GPT-5.6 Sol                    |  | Claude Sonnet                  |    |
|  | 14 models                      |  | 8 models                       |    |
|  |                                |  |                                |    |
|  | Test              Manage ->    |  | Test              Manage ->   |    |
|  +--------------------------------+  +--------------------------------+    |
|                                                                            |
|  +--------------------------------+  +--------------------------------+    |
|  | OpenRouter                ... |  | Local LLM                 ... |    |
|  | OpenRouter                     |  | OpenAI-compatible              |    |
|  |                                |  |                                |    |
|  | Credential required            |  | Disabled                       |    |
|  | No default model               |  | llama-3.3-70b                  |    |
|  | 0 models                       |  | 3 models                       |    |
|  |                                |  |                                |    |
|  |                  Configure     |  |                     Manage ->  |    |
|  +--------------------------------+  +--------------------------------+    |
|                                                                            |
+----------------------------------------------------------------------------+
```

### Card hierarchy

Each provider card should communicate:

1. provider icon and connection name
2. provider type
3. presentation state
   - Ready
   - Disabled
   - Credential required
   - Model required
4. default-connection badge when applicable
5. default model or no-default state
6. model count
7. direct Test action when usable
8. Manage / Configure action
9. overflow menu for secondary actions such as Make Default, Edit, Enable/Disable, Delete

Search should match connection name, provider name/type, default model ID/display name, and endpoint where useful.

## Provider workspace

```text
+----------------------------------------------------------------------------+
| < AI Providers                                                            |
|                                                                            |
| OpenAI  Personal                              Ready        DEFAULT          |
|                                                                            |
|                              Test Connection    Edit    ...                 |
|                                                                            |
|        Overview              Models              Connection                |
|        --------                                                            |
+----------------------------------------------------------------------------+
|                                                                            |
|                        < selected section >                                |
|                                                                            |
+----------------------------------------------------------------------------+
```

Use three tabs:

- Overview
- Models
- Connection

This is intentionally similar to MCP server detail navigation while keeping provider-specific concerns distinct.

## Overview

Overview answers: "Is this provider usable, and what will BYOKchat use by default?"

```text
OVERVIEW

+------------------------------------+
| Status                             |
| Ready                              |
| Enabled                            |
| Credential stored in Keychain     |
| Last test: Connection succeeded    |
+------------------------------------+

+------------------------------------+
| Default                            |
| Default connection       Yes       |
| Default model       GPT-5.6 Sol    |
|                         Change     |
+------------------------------------+

+------------------------------------+
| Models                             |
| 14 available                       |
| 3 favorites                        |
|                         View ->     |
+------------------------------------+
```

Overview should not expose raw editable connection fields.

## Models

Models becomes a dedicated management surface rather than rows embedded in a grouped form.

```text
+----------------------------------------------------------------------------+
| Models                                                      Refresh        |
| [ Search models                                      ]       + Add Model    |
+----------------------------------------------------------------------------+
|                                                                            |
| * GPT-5.6 Sol                                      DEFAULT       visible ...|
|   gpt-5.6-sol                                                              |
|   Available                                                                |
|                                                                            |
|   GPT-5.6 Luna                                                 visible ... |
|   gpt-5.6-luna                                                             |
|   Available                                           Make Default          |
|                                                                            |
| * GPT-5.5                                                      visible ... |
|   gpt-5.5                                                                  |
|   Available                                           Make Default          |
|                                                                            |
| -------------------------------------------------------------------------- |
| Hidden Models                                                   Show (2)   |
+----------------------------------------------------------------------------+
```

Preserve existing model capabilities:

- refresh discovered models when the provider supports discovery
- add a manual model ID
- favorite/unfavorite
- hide/show
- make default
- indicate unavailable models without losing them from management

Manual model entry should use a compact sheet rather than a permanently visible text field.

```text
+-------------------------------------+
| Add Model                           |
|                                     |
| Model ID                            |
| [ gpt-5.6-sol                     ] |
|                                     |
|                 Cancel      Add     |
+-------------------------------------+
```

## Connection

Technical BYOK configuration belongs here.

### Built-in provider

```text
CONNECTION

+----------------------------------------------------------------------+
| Endpoint                                                        Edit |
|                                                                      |
| https://api.openai.com/v1                                            |
| Using provider default endpoint                                      |
+----------------------------------------------------------------------+

+----------------------------------------------------------------------+
| Authentication                                                  Edit |
|                                                                      |
| Bearer Token                                                         |
| Credential stored securely in Keychain                               |
+----------------------------------------------------------------------+

+----------------------------------------------------------------------+
| Custom Headers                                                  Edit |
|                                                                      |
| No custom headers                                                    |
+----------------------------------------------------------------------+

                                                 Test Connection

------------------------------------------------------------------------
Danger Zone

Delete Connection...
```

### OpenAI-compatible provider

```text
+----------------------------------------------------------------------+
| Endpoint                                                        Edit |
|                                                                      |
| Base URL           http://192.168.1.20:11434/v1                      |
| Chat endpoint      /chat/completions                                 |
| Models endpoint    /models                                           |
+----------------------------------------------------------------------+

+----------------------------------------------------------------------+
| Authentication                                                  Edit |
|                                                                      |
| Custom Header                                                        |
| X-API-Key                                                            |
| Credential stored in Keychain                                        |
+----------------------------------------------------------------------+

+----------------------------------------------------------------------+
| Headers                                                         Edit |
|                                                                      |
| X-Foo             ********                                           |
| X-Client          BYOKchat                                           |
+----------------------------------------------------------------------+
```

Never expose a stored secret value in the overview cards. Keep Keychain reveal/edit behavior in a focused credential editor.

## Add provider flow

The first step should be provider selection rather than a menu attached to the bottom of a sidebar.

```text
+--------------------------------------------------------------+
| Add AI Provider                                         x    |
| Choose a service to connect.                                |
+--------------------------------------------------------------+
|                                                              |
| +-------------------+  +-------------------+                 |
| | OpenAI            |  | Anthropic         |                 |
| | GPT models        |  | Claude models     |                 |
| +-------------------+  +-------------------+                 |
|                                                              |
| +-------------------+  +-------------------+                 |
| | Gemini            |  | DeepSeek          |                 |
| +-------------------+  +-------------------+                 |
|                                                              |
| +-------------------+  +-------------------+                 |
| | OpenRouter        |  | NVIDIA            |                 |
| +-------------------+  +-------------------+                 |
|                                                              |
| ------------------------------------------------------------ |
| OpenAI-compatible Server                                     |
| Connect Ollama, LM Studio, a LAN server, or another API  ->  |
|                                                              |
+--------------------------------------------------------------+
```

### Built-in provider connection

```text
+--------------------------------------------------------------+
| Connect OpenAI                                          x    |
+--------------------------------------------------------------+
|                                                              |
| Connection name                                              |
| [ Personal OpenAI                                      ]     |
|                                                              |
| API Key                                                      |
| [ **************************************************** ]     |
| Credentials are stored in Keychain.                          |
|                                                              |
| Advanced                                                     |
| > Endpoint override                                          |
| > Custom headers                                             |
|                                                              |
|                                      Cancel   Connect         |
+--------------------------------------------------------------+
```

### OpenAI-compatible connection

```text
Connect OpenAI-compatible

Name
[ Local Ollama                  ]

Base URL
[ http://localhost:11434/v1     ]

Authentication
[ None                       v  ]

Chat path
[ /chat/completions             ]

Models path
[ /models                       ]

Seed models (optional)
[ llama3.3                      ]
[ qwen3                         ]

Advanced
> Custom headers

                         Connect
```

OpenAI-compatible connections expose the technical fields up front because those fields define the connection itself.

## Editing strategy

Avoid recreating the current 620 x 650 all-in-one editor. Prefer focused editors:

- Connection Identity: connection name
- Endpoint: override or OpenAI-compatible base/chat/models paths
- Authentication: auth mode, header name, credential replacement/reveal
- Headers: additional header editor
- Provider metadata: OpenRouter app title / HTTP referer when applicable

For initial implementation, these focused editors may share one backing draft type and persistence call as long as the UI is separated by task.

## Existing behavior that must remain intact

- provider free-tier/account-capacity gating
- built-in provider defaults
- OpenAI-compatible HTTP/HTTPS and LAN endpoints
- bearer/custom-header/no-auth support
- credentials stored in Keychain
- reveal credential behavior
- custom headers
- OpenRouter app title and HTTP referer metadata
- model discovery and refresh
- manual seed models
- manual model addition
- favorite / hide model state
- default provider account
- default model
- test connection
- enable/disable connection
- deletion
- target picker behavior and preferred-target repair

## Implementation boundary

This redesign is a presentation and information-architecture change. It should not introduce a provider storage migration or alter the underlying provider APIs unless a small helper is needed to expose presentation state cleanly.

## Acceptance criteria

- AI Providers no longer embeds its own `NavigationSplitView`.
- The top-level surface is a searchable flat provider collection.
- Selecting a provider drills into Overview / Models / Connection.
- Existing provider capabilities remain reachable.
- Model management is first-class and searchable.
- Add provider begins with a provider picker.
- Built-in provider setup is simple; OpenAI-compatible setup exposes its required technical fields.
- Credentials are never rendered in summary cards.
- The screen uses the same themed cards, spacing, separators, and hierarchy as Library, MCP, and Projects.
- The final branch builds successfully through the macOS deploy worker.
