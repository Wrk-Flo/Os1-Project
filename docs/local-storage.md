# Local Storage Runbook

OS1 should stay local-first when Azure is unavailable or intentionally disabled.
Keep the repo small, keep model weights outside the repo, and treat build
outputs as replaceable. The storage scripts only inspect filesystem sizes; they
do not read env files, tokens, keys, Keychain items, or Hermes config contents.

## Daily Checks

Run the report before long 24/7 sessions and before pulling large models:

```sh
scripts/os1-storage-report.sh
```

Preview cleanup first:

```sh
scripts/os1-clean-storage.sh --all
```

Apply cleanup only after the dry-run output looks right:

```sh
scripts/os1-clean-storage.sh --all --apply
```

Models are never deleted by the cleanup helper. To include model cache sizes in
the cleanup output:

```sh
scripts/os1-clean-storage.sh --all --models-report
```

## What Belongs Where

Commit source, tests, docs, scripts, manifests, lockfiles, small deterministic
assets, and release metadata that humans need to review.

Do not commit local build products, SwiftPM caches, Xcode DerivedData, `dist/`,
logs, `.worktrace/`, local Hermes state, local provider env files, private keys,
certificates, Ollama models, GGUF model files, Hugging Face caches, DVC caches,
MinIO data directories, or generated archives.

Use GitHub for source, issues, reviews, and small text artifacts. Use GitHub
Releases for signed app zips, checksums, and public release notes. Use Git LFS
only for reviewed binary assets that must version with the repo; do not use it
for routine build output or local model caches. Use GitHub Actions cache for
ephemeral CI dependencies such as SwiftPM cache directories. Use Hugging Face
for public or team-shareable model weights. Use DVC for datasets or repeatable
large artifacts with a configured remote. Use MinIO for local/LAN object storage
when artifacts need object-store semantics but should not leave the site. Use an
external SSD for hot local model storage on limited internal disks.

## External Model Storage

Use a dedicated external volume for model files. These examples assume it is
mounted at `/Volumes/OS1-Models`.

```sh
export OS1_MODELS=/Volumes/OS1-Models
mkdir -p "$OS1_MODELS/ollama" "$OS1_MODELS/gguf" "$OS1_MODELS/huggingface"
```

Move existing Ollama models, then make Ollama use the external directory:

```sh
rsync -a --info=progress2 "$HOME/.ollama/models/" "$OS1_MODELS/ollama/"
launchctl setenv OLLAMA_MODELS "$OS1_MODELS/ollama"
osascript -e 'quit app "Ollama"' || true
open -a Ollama
ollama list
```

For shell-launched Ollama instead of the macOS app:

```sh
OLLAMA_MODELS="$OS1_MODELS/ollama" ollama serve
```

After `ollama list` shows the expected models from the external path, remove
the old internal copy:

```sh
rm -rf "$HOME/.ollama/models"
```

Persist Hugging Face cache paths for new shells:

```sh
cat >> "$HOME/.zshrc" <<'EOF'
export OS1_MODELS=/Volumes/OS1-Models
export HF_HOME="$OS1_MODELS/huggingface"
export HUGGINGFACE_HUB_CACHE="$HF_HOME/hub"
EOF
```

Store llama.cpp GGUF files on the external volume and point the server at the
absolute model path:

```sh
export OS1_MODELS=/Volumes/OS1-Models
mkdir -p "$OS1_MODELS/gguf"
curl -L \
  -o "$OS1_MODELS/gguf/Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf" \
  "https://huggingface.co/bartowski/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf"
llama-server \
  -m "$OS1_MODELS/gguf/Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf" \
  --host 127.0.0.1 \
  --port 8080 \
  -c 8192
```

Configure Hermes/OS1 to use that local llama.cpp server:

```sh
LLAMA_CPP_MODEL="$OS1_MODELS/gguf/Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf" \
  scripts/configure-local-oss-models.sh llama-cpp
```

## Artifact Storage Choices

GitHub Releases:

```sh
scripts/package-github-release.sh
gh release create vX.Y.Z dist/OS1.app.zip dist/OS1.app.zip.sha256 --draft
```

Git LFS for a reviewed binary asset that must live with the repo:

```sh
git lfs install
git lfs track "Assets/**/*.bin"
git add .gitattributes Assets/example.bin
```

DVC with a local or external remote:

```sh
dvc init
dvc remote add -d os1-models /Volumes/OS1-Models/dvc
dvc add data/large-dataset
git add data/large-dataset.dvc .dvc/config
```

MinIO for LAN-local object storage:

```sh
mkdir -p /Volumes/OS1-Models/minio
MINIO_ROOT_USER=os1admin MINIO_ROOT_PASSWORD=change-this-local-password \
  minio server /Volumes/OS1-Models/minio --address 127.0.0.1:9000
```

GitHub Actions cache should stay CI-only. Cache dependency directories by a
manifest hash and never commit the cache output:

```yaml
- uses: actions/cache@v4
  with:
    path: |
      .swiftpm-home/cache
      .swiftpm-home/module-cache
    key: swiftpm-${{ runner.os }}-${{ hashFiles('Package.resolved') }}
```

## Cleanup Commands

Repo-local build and release cleanup:

```sh
scripts/os1-clean-storage.sh --build-caches --test-caches --dist
scripts/os1-clean-storage.sh --build-caches --test-caches --dist --apply
```

Repo-local logs and trace cleanup:

```sh
scripts/os1-clean-storage.sh --logs
scripts/os1-clean-storage.sh --logs --apply
```

Manual model cleanup is intentionally separate from the script. Verify the
external model path first, then remove only the old internal copy:

```sh
scripts/os1-storage-report.sh
ollama list
rm -rf "$HOME/.ollama/models"
```
