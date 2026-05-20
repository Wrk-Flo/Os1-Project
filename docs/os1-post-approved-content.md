# OS1 Post-Approved Content Sidecar

This runbook covers `scripts/os1-post-approved-content.sh`, the operator-side
handoff for content that has already been reviewed and approved. The script
defaults to `--dry-run`; use `--apply` only after inspecting the generated
artifacts and confirming the target channels.

## Inputs

- `--content PATH`: required markdown content file. A leading `# Heading`
  becomes the title or email subject; the remaining markdown becomes the body.
- `--channels CSV`: one or more of `linkedin`, `gmail-draft`, `twitter`.
  Default is `linkedin,gmail-draft`.
- `--gmail-to ADDR`: required when `gmail-draft` is selected.
- `--linkedin-visibility PUBLIC|CONNECTIONS`: defaults to `CONNECTIONS`.
- `--out DIR`: per-run artifact directory. If omitted, the script writes under
  `~/Library/Application Support/OS1/posts/runs/<timestamp>/`.

## Current Channel Policy

- `linkedin`: active Composio channel. Dry-run writes the request payload and
  does not post.
- `gmail-draft`: active fallback channel. Apply mode creates a draft only; it
  does not send mail.
- `twitter`: guarded until OAuth is complete. When the connected account is not
  active, the script records a skip and points back to
  `docs/composio-integration-state.md`.

## Dry-Run Checks

Use a temporary markdown file for smoke checks:

```bash
tmp_content="$(mktemp -t os1-approved-content.XXXXXX.md)"
printf '# OS1 Approved Post\n\nDry-run validation content.\n' > "$tmp_content"

./scripts/os1-post-approved-content.sh \
  --content "$tmp_content" \
  --channels linkedin,gmail-draft \
  --gmail-to mo.tut.liech@gmail.com \
  --dry-run
```

Check Twitter separately so its OAuth state is explicit:

```bash
./scripts/os1-post-approved-content.sh \
  --content "$tmp_content" \
  --channels twitter \
  --dry-run
```

Unknown channels are usage errors and should exit `2`:

```bash
./scripts/os1-post-approved-content.sh \
  --content "$tmp_content" \
  --channels unknown \
  --dry-run
```

## Secret Handling

The script reads the Composio API key from `~/.composio/api_key` or
`OS1_COMPOSIO_API_KEY_FILE`, keeps it in memory, and must not print it. Report
credential state only as `set`, `missing`, or `empty`.

## Apply Checklist

1. Run `bash -n scripts/os1-post-approved-content.sh`.
2. Run the relevant `--dry-run` command and inspect the `posts-run.md` summary.
3. Confirm the selected channels and recipient.
4. Run with `--apply` only for approved content.
5. Preserve generated artifacts for audit.
