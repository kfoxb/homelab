# AdGuard Home

Runs on a Rock64 board (2GB RAM, ARM64) — NOT on the K3s cluster.
DNS is kept separate so a cluster outage doesn't take down the family's internet.

## Setup

```bash
# On the Rock64, after installing a lightweight Linux distro:
curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
```

Then open http://<rock64-ip>:3000 for initial setup wizard.

## Configuration

- Enable parental controls (built-in adult content filters)
- Enable safe search enforcement (Google, Bing, YouTube)
- Configure per-device rules (stricter for kids' devices)
- Point router DNS to the Rock64's IP
