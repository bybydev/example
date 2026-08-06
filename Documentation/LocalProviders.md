# Private-Network Providers

BYOKchat supports user-defined OpenAI-compatible providers running on the local network, including Ollama- and LM Studio-style endpoints.

## Endpoint policy

HTTPS remains the default and is required for public internet endpoints.

Plain HTTP requires an explicit per-provider opt-in and is accepted only for:

- `localhost`
- unqualified local host names
- `.local` host names
- private or link-local IPv4 addresses
- loopback, unique-local, or link-local IPv6 addresses

Public HTTP endpoints remain rejected even when local HTTP is enabled.

## iOS networking

The app declares a local-network purpose string and enables ATS local networking only. It does not enable global arbitrary network loads.

The iPhone must be able to reach the host and the user must grant Local Network access. Simulator and physical-device host addresses may differ.

## Authentication

Local providers may use bearer authentication, a named credential header, or explicit no-auth mode. No-auth is represented directly; BYOKchat does not create fake credentials.
