# Claude Code Agents

Kubernetes infrastructure for running Claude Code agents autonomously on the cluster.

## Setup

### 1. Create the namespace

```bash
kubectl apply -f agents/namespace.yaml
```

### 2. Apply credentials

Copy the example secret and fill in your real values:

```bash
cp agents/secrets.yaml.example agents/secrets.yaml
# Edit agents/secrets.yaml with your actual keys
kubectl apply -f agents/secrets.yaml
```

`agents/secrets.yaml` is gitignored and will never be committed.

Required fields:
- `ANTHROPIC_API_KEY` — your Anthropic API key
- `GITHUB_TOKEN` — a GitHub personal access token with repo read/write access

## Planned

- **Ticket triage**: CronJob that checks for newly assigned tickets,
  investigates the codebase, and writes triage summaries
- **PR comment handler**: Job triggered by GitHub webhook to address
  PR review comments
- **Background research**: Long-running Jobs for codebase exploration
  and planning
