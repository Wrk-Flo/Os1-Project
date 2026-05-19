# Business Use Cases

OS1 can already support useful local-first business operations while Azure is
disabled. The reliable pattern is: keep data local, use Ollama for bounded
language tasks, keep CUA approval-gated, and use the health monitor before
trusting long-running sessions.

## Required Local Components

- OS1 repo and app build scripts
- Hermes Agent CLI under `~/.local/bin/hermes`
- Ollama on `http://127.0.0.1:11434`
- `qwen2.5-coder:3b` for the default local model
- OS1 health LaunchAgent for 24/7 monitoring
- Optional CUA driver for guarded computer-use workflows

Check the baseline:

```sh
scripts/os1-local-ops-health.sh
scripts/os1-production-readiness.sh --local
```

Run the business smoke suite:

```sh
scripts/os1-business-smoke.sh
scripts/os1-business-smoke.sh --quick
```

Write smoke outputs for review:

```sh
scripts/os1-business-smoke.sh --output-dir .worktrace/business-smoke
```

`.worktrace/` is ignored and should not be committed.

## Daily Operations Brief

Use OS1 to summarize local operating signals into a morning status:

- health monitor state
- disk headroom
- model availability
- CI/release state
- operator priorities
- current blockers

Command smoke:

```sh
scripts/os1-business-smoke.sh --quick
```

Human approval is required before acting on financial, legal, customer, or
deployment recommendations.

## Customer Support Triage

Use the local model to classify inbound messages by category, urgency, and next
action. Keep raw customer data local unless a separate policy permits cloud
processing.

Good local tasks:

- sort messages by urgency
- draft short response options
- identify missing context
- flag install/signing/notarization issues

Human approval is required before sending customer replies.

## Project Task Extraction

Use OS1 to turn notes, meeting summaries, or planning text into tasks:

- checkbox task lists
- owner/action/date extraction
- risk and dependency lists
- release checklist drafts

The local model is well suited to short notes. For long histories, summarize in
chunks first.

## Research Notes

Use local inference for private synthesis of notes already on the Mac:

- compare internal docs
- draft outlines
- extract decisions
- create local-only summaries

If web freshness or exact citations matter, use normal research tooling and
record sources. Do not ask the local model to invent citations.

## Cron And Recurring Summaries

Hermes Agent has cron support; OS1 can supervise the local runtime and monitor
health. Use recurring jobs for bounded summaries:

- daily local operations brief
- weekly project-risk digest
- unread support queue categorization
- release checklist reminder

Keep recurring jobs read-only unless the operator has approved the exact write
or send action.

## Guarded CUA Workflows

CUA computer-use should remain opt-in and approval-gated. Appropriate local
workflows include:

- inspect a local app screen
- collect UI state for a human review
- perform a one-shot approved task

Do not run unattended CUA flows that can send messages, move money, delete
files, change production services, or alter credentials.

Current known state: `cua-driver` is installed, but a running CUA driver process
is optional and may be absent until needed.

## Safety Boundaries

- Keep Azure mutation flags unset while Azure is disabled.
- Do not print or commit secrets.
- Keep model weights, build products, logs, and local state out of git.
- Treat local model output as draft work.
- Require human approval for external sends, payments, credential changes,
  customer-facing replies, production deploys, and destructive file actions.

## Verification

Before using OS1 for live local business operations:

```sh
scripts/os1-local-ops-health.sh
scripts/os1-business-smoke.sh --quick
scripts/os1-production-readiness.sh --local
```

Before public release:

```sh
scripts/os1-production-readiness.sh --public
```

The public gate is expected to fail until Developer ID signing and notarization
are configured.
