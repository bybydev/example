# Model path fixtures

These tiny files preserve the exact production `Models/` directory and filename contract without committing model weights.

They are intentionally not inference-capable weights. They exercise model discovery, missing-file handling, and corrupt-file handling while keeping repository size negligible. `scripts/install-model-fixtures.sh` copies them into the ignored `Models/` tree without changing any runtime path.
