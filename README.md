# OmniCP — deployment files

Everything needed to run OmniCP on one host: the compose definitions, the four TLS
configurations, and the two scripts. **No source code and no credential** — this repository is
public precisely so that a new deployment starts with a `git clone` and nothing to ask for.

**Start at [INSTALL.md](INSTALL.md).** About twenty minutes, most of which is DNS.

```bash
git clone https://github.com/armar-reggans/omnicp-install.git /opt/docker/omnicp
cd /opt/docker/omnicp
cp .env.production.example .env.production   # then fill it in
./scripts/preflight.sh
```

## What you still need from us

A **read-only registry token** for `ghcr.io`, and an **exact release tag**. The images are
private and that token is what a subscription controls. When a subscription lapses,
`docker compose pull` stops working and you stop receiving updates — **a running deployment
keeps running.** Nothing here phones home, checks a licence at runtime, or degrades on its own.

## Versions

This repository is tagged with the same release tags as the images, and it is **generated** —
`v2026.10.29c` of these files is the set that release was built and tested with. Pull requests
cannot be accepted here for that reason; send them to us and they will come back through a
release. Issues are welcome.

## Licence

Business Source License 1.1 — see [LICENSE](LICENSE). Run it to operate your own service;
do not offer OmniCP itself to third parties as a product or a hosted control panel.
