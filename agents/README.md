# Claude Code Agents

Kubernetes Jobs and CronJobs for running Claude Code agents on the cluster.

## Planned

- **Ticket triage**: CronJob that checks for newly assigned tickets,
  investigates the codebase, and writes triage summaries
- **PR comment handler**: Job triggered by GitHub webhook to address
  PR review comments
- **Background research**: Long-running Jobs for codebase exploration
  and planning
