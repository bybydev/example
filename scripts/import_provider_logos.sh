#!/usr/bin/env bash
set -euo pipefail

# Import monochrome provider marks from the pinned Lobe Icons SVG package.
# Run from anywhere; output always targets this repository's asset catalog.

readonly package_version="1.94.0"
readonly package_url="https://registry.npmjs.org/@lobehub/icons-static-svg/-/icons-static-svg-${package_version}.tgz"
readonly package_integrity="sha512-Inx1TYkjLH6YeHOIHeVW9+OM/xxRnk8TmcQVKquFUDBmE3X9sUuRGt7kALrrDBNNAbrWz7Qq6fAiFj9E9Mmw9Q=="
readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repository_dir="$(cd "${script_dir}/.." && pwd)"
readonly asset_catalog="${repository_dir}/BYOKchat/Resources/Assets.xcassets"
readonly staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/byok-provider-logos.XXXXXX")"
readonly archive_path="${staging_dir}/icons.tgz"

curl --fail --location --silent --show-error "${package_url}" --output "${archive_path}"
actual_integrity="sha512-$(openssl dgst -sha512 -binary "${archive_path}" | openssl base64 -A)"
if [[ "${actual_integrity}" != "${package_integrity}" ]]; then
  echo "Provider icon package failed its integrity check." >&2
  exit 1
fi
tar -xzf "${archive_path}" -C "${staging_dir}"

icons=(
  "ai21:ai21"
  "alibaba:alibaba"
  "anthropic:anthropic"
  "aws-bedrock:bedrock"
  "azure-ai:azureai"
  "baseten:baseten"
  "cerebras:cerebras"
  "cloudflare-workers-ai:workersai"
  "cohere:cohere"
  "deepinfra:deepinfra"
  "deepseek:deepseek"
  "fal:fal"
  "fireworks:fireworks"
  "gemini:gemini"
  "groq:groq"
  "huggingface:huggingface"
  "hyperbolic:hyperbolic"
  "ibm-watsonx:ibm"
  "lmstudio:lmstudio"
  "meta:meta"
  "minimax:minimax"
  "mistral:mistral"
  "moonshot:moonshot"
  "nebius:nebius"
  "nvidia:nvidia"
  "ollama:ollama"
  "openai:openai"
  "openrouter:openrouter"
  "perplexity:perplexity"
  "qwen:qwen"
  "replicate:replicate"
  "sambanova:sambanova"
  "siliconflow:siliconcloud"
  "snowflake:snowflake"
  "together:together"
  "vercel-ai:vercel"
  "vertex-ai:vertexai"
  "xai:xai"
  "zai:zai"
)

for item in "${icons[@]}"; do
  asset="${item%%:*}"
  source_slug="${item##*:}"
  imageset="${asset_catalog}/provider.${asset}.imageset"
  filename="provider.${asset}.svg"

  mkdir -p "${imageset}"
  sed \
    -e 's/fill="currentColor"/fill="#000000"/' \
    -e 's/ height="1em"//' \
    -e 's/ style="flex:none;line-height:1"//' \
    -e 's/ width="1em"//' \
    "${staging_dir}/package/icons/${source_slug}.svg" > "${imageset}/${filename}"

  printf '%s\n' \
    '{' \
    '  "images" : [' \
    '    {' \
    "      \"filename\" : \"${filename}\"," \
    '      "idiom" : "universal"' \
    '    }' \
    '  ],' \
    '  "info" : {' \
    '    "author" : "xcode",' \
    '    "version" : 1' \
    '  },' \
    '  "properties" : {' \
    '    "preserves-vector-representation" : true,' \
    '    "template-rendering-intent" : "template"' \
    '  }' \
    '}' > "${imageset}/Contents.json"
done

echo "Imported ${#icons[@]} provider logos into ${asset_catalog}"
