# Installing OmniCP

This brings up a complete OmniCP deployment on one host: the panel, its database, the
reconciler, the console proxy and monitoring, behind TLS.

It takes about twenty minutes, most of which is DNS. Nothing here builds anything — the
images are pulled, so the host needs no Node, no pnpm, no compiler and no spare memory for a
build.

---

## 1. What you need from us before you start

Two things. Ask if you are missing either; neither can be obtained without us.

| | What it is |
|---|---|
| **A registry token** | A read-only GitHub token for `ghcr.io`. This is how you receive images, and it is the thing a subscription controls. |
| **A version to install** | An exact release tag, e.g. `v2026.10.31a`. There is no `latest` to pull and never will be. |

You do **not** need access to the OmniCP source repository. The deployment files — this
document, `compose.yaml`, the Caddy configurations and the three scripts — are published openly
at [`armar-reggans/omnicp-install`](https://github.com/armar-reggans/omnicp-install) and clone
with no credential at all.

> **What the licence controls, plainly.** The token is what lapses if a subscription does.
> When it does, `docker compose pull` stops working and you stop receiving updates. **It never
> stops a running deployment.** Nothing in OmniCP phones home, checks a licence at runtime, or
> degrades on its own. A panel that is running keeps running.

---

## 2. What the host needs

A Linux host with Docker and the compose **plugin**. Nothing else.

```bash
apt-get update
apt-get install -y docker.io docker-compose-v2
systemctl enable --now docker
```

Any Docker with `docker compose` as a subcommand works. The separate `docker-compose` v1
binary does not, and the preflight script in step 5 will tell you so.

**Sizing.** We have not measured a floor, so take this as a starting point rather than a
promise: 2 vCPU, 4 GB RAM and 40 GB of disk is comfortable for a first deployment. For
reference, our own production runs the full stack on 7.9 GB alongside other workloads. The two
images total about 1.2 GB and share a base layer.

**Ports.** 80 and 443 must be free, unless you choose the tunnel mode in step 4, which opens no
inbound ports at all.

---

## 3. DNS

Point the hostname you intend to use at this host before going further. Certificate issuance
in the default mode needs the name to resolve here already, and when it does not, the symptom
is a Caddy failure that looks nothing like a DNS problem.

```bash
dig +short panel.example.com      # must return this host's public address
```

---

## 4. Choose how TLS is terminated

Four modes. Pick one now; it is one line of configuration, but the modes differ in where the
**client's address** comes from, and getting that wrong puts every user of the panel into one
login rate-limit bucket.

| `TLS_MODE` | Use it when | Needs |
|---|---|---|
| `acme` *(default)* | The host is reachable from the internet on 80 and 443 | DNS resolving here |
| `own-cert` | You have your own certificate | `panel.crt` (leaf + chain) and `panel.key`. You renew them |
| `cloudflare` | You are behind Cloudflare's proxy | A Cloudflare Origin Certificate, same two filenames |
| `tunnel` | You want no inbound ports at all | A Cloudflare Tunnel connector token |

Read the matching file in `caddy/` before using anything but the default.

---

## 5. Get the files and configure

```bash
git clone --branch v2026.10.31a \
  https://github.com/armar-reggans/omnicp-install.git /opt/docker/omnicp
cd /opt/docker/omnicp
```

That repository is public and holds nothing but these deployment files — no source, no
credential. It carries the **same release tags as the images**, so cloning the tag you are
installing gives you the `compose.yaml` that release was tested with rather than whichever one
happens to be newest.

Cloning a tag leaves git in *detached HEAD*, which is correct here and is not something to fix:
this host runs a pinned release and has no commits of its own. `scripts/update.sh` moves the
checkout to the next tag for you when you upgrade.

### The short way

```bash
./scripts/install.sh
```

It asks for the hostname, how TLS is terminated, the release tag and the first administrator;
it **generates** `POSTGRES_PASSWORD` and `PANEL_ENCRYPTION_KEY`, because neither should ever
be a human's choice. Then it writes `.env.production` from the example — with every one of its
explanations still in it — runs the preflight checks, logs in to the registry if you have not
already, pulls, starts the stack and creates that administrator.

It is safe to run twice, and that is the point rather than a nicety: an `.env.production` that
already exists is read and **never rewritten**, so an install that failed at the pull resumes
instead of starting over with secrets that no longer match the database it created.

The rest of this section and the next one are what it does. Read them if this deployment needs
to differ from what the script assumes, or if you would rather do it by hand — the two routes
end in the same place, and the script is not doing anything you could not.

### By hand

```bash
cp .env.production.example .env.production
```

Every variable is explained in that file. Five are required — the stack refuses to start
without them — plus three that select the registry, which are present but commented out in the
example:

```ini
# The database. Use the same password in both lines.
POSTGRES_PASSWORD=<generate one>
DATABASE_URL=postgresql://onepanel:<same password>@postgres:5432/onepanel

# Must decode to EXACTLY 32 bytes. Generate it, do not invent it.
PANEL_ENCRYPTION_KEY=<openssl rand -base64 32>

# Your hostname, twice. PANEL_ORIGIN is the CSRF allow-list.
PANEL_DOMAIN=panel.example.com
PANEL_ORIGIN=https://panel.example.com
PANEL_PUBLIC_URL=https://panel.example.com

# Receive images rather than build them.
OMNICP_SOURCE=pull
OMNICP_REGISTRY=ghcr.io/armar-reggans
OMNICP_VERSION=v2026.10.31a
```

Generate the two secrets rather than choosing them:

```bash
openssl rand -base64 32     # PANEL_ENCRYPTION_KEY — must be exactly 32 bytes decoded
openssl rand -base64 24     # POSTGRES_PASSWORD
```

> ### `PANEL_ENCRYPTION_KEY` is the one value that cannot be regenerated
>
> It seals every region credential, TOTP enrolment and IdP secret in the database. Lose it and
> those are not recoverable from any backup of the database alone — the data is still there and
> nothing can open it. **Store it somewhere other than this host, before you continue.**
>
> A hand-typed phrase almost certainly will not decode to 32 bytes, and the panel refuses to
> start rather than starting and failing later.

Then check everything before anything starts:

```bash
./scripts/preflight.sh
```

It needs only bash — no images, no database — because the moment it is most useful is the
moment none of those exist. It checks every required variable, that the encryption key decodes
to 32 bytes, that Docker and the compose plugin are present, and that the ports are free.
Errors stop it; warnings do not.

---

## 6. Bring it up

`./scripts/install.sh` has already done everything in this section. Skip to §7.

```bash
docker login ghcr.io -u <the username we gave you>   # paste the token, not a password
docker compose --env-file .env.production pull
docker compose --env-file .env.production up -d
```

The username is **the one that owns the token we issued, not your own GitHub account** — a
`ghcr.io` token only authenticates as its owner, and logging in as anyone else is refused.

For `TLS_MODE=tunnel`, the last command takes an extra file:

```bash
docker compose --env-file .env.production -f compose.yaml -f compose.tunnel.yaml up -d
```

**The database sets itself up.** The `migrate` service applies every migration and runs every
seed before the panel is allowed to start, and records what this database received. There is no
separate migrate step to remember and no catalog to seed by hand.

Then create the first administrator — the only step that needs a human, because it is the only
one that invents a credential:

```bash
docker compose --env-file .env.production run --rm tools pnpm bootstrap
```

---

## 7. First steps in the panel

Sign in at `https://panel.example.com` as the administrator you just created.

1. **Enrol MFA.** It is mandatory for this role, and a brand-new administrator is the one state
   where the panel cannot enforce it yet.
2. **Register a region** at `/admin/regions` and paste its `serveradmin` secret. The secret is
   sealed under `PANEL_ENCRYPTION_KEY` and never written to a file. A region is a database row,
   not configuration — adding one later is an ordinary operational act, never a redeployment.
3. **Probe it.** A region cannot become `ACTIVE` until a probe passes. A first region that fails
   here is failing loudly on purpose.
4. **Curate the catalog** at `/admin/catalog` — the images, templates and sizes your tenants may
   choose from.
5. **Check how long the audit log is kept** at `/admin/settings`. It is **90 days** by
   default, and the first reconciler pass after installing or upgrading deletes anything older
   than that. On a fresh install there is nothing older, so this is a decision you are making
   for later rather than now — but it is the one setting on that page with no undo, and the
   page tells you how many rows the current window would remove before it removes them.

   Account owners read their own share of that log at `/settings/activity` and can pull it into
   their own SIEM from `/api/v1/activity`. What they are served is what the page shows: no
   provider error codes, no internal method names, no host or datastore names, and your staff
   named by role rather than by address.
6. **Set prices** at `/admin/prices` if you intend to bill. OmniCP ships with none deliberately:
   usage no price covers is flagged rather than billed at zero, and an invoice carrying unpriced
   hours refuses to issue.

---

## 8. Confirm it is healthy

`/admin/status` is the page to know. It reports every component the panel can observe — the
database, each worker, each region — and it judges them by what they **do** rather than by a
container being up, because a wedged worker and a healthy one look identical to Docker.

On releases **after `v2026.10.29b`** it also states, at the top, which release is deployed and
how many migrations the database has. That is the first thing to quote if you contact us. On
`v2026.10.29b` itself the page exists but does not show the version, so quote the
`OMNICP_VERSION` line from your `.env.production` instead.

---

## 9. Host-specific settings

Anything true of this host and no other — an internal DNS resolver, a published port, a wider
memory limit — goes in `compose.override.yaml`, which compose merges automatically:

```bash
cp compose.override.yaml.example compose.override.yaml   # then edit
```

**Do not edit `compose.yaml`.** An upgrade checks out a new tag over it, so an edit there is
either lost without warning or, if you commit it to keep it, replayed forever until the day it
conflicts — and that day is a hand-resolved merge, at speed, on a production system, in a file
whoever is resolving it did not write. The override file is gitignored and survives every
update untouched. `scripts/update.sh` refuses to run at all on a dirty checkout, for this
reason.

---

## 10. Upgrading

Edit one line and run one script:

```ini
OMNICP_VERSION=v2026.11.05
```

```bash
./scripts/update.sh
```

It fetches that tag, moves the deployment files to it, pulls the new images, applies
migrations, and restarts. Nothing is stopped until the new images are present, so a failed pull
leaves the running panel alone.

Because one tag names both the files and the images, the `compose.yaml` you end up running is
always the one that release was tested with.

Upgrades are never automatic and there is no moving tag, so nothing changes under you on a
restart or a reboot. The version you chose is the version you keep until you choose another.

---

## 11. Back up these three things

1. **The database.** `pg_dump` from the postgres service. Everything the panel knows: tenants,
   regions, catalog, audit log, invoices.
2. **`PANEL_ENCRYPTION_KEY`** — and **not to the same place as the database dump.** Region
   secrets and TOTP enrolments are ciphertext in those rows, so a dump without the key cannot
   talk to any region, and a dump stored beside the key has undone the reason for encrypting
   them. Two destinations, deliberately.
3. **`.env.production`** and `compose.override.yaml` — quick to recreate, annoying to recreate
   correctly.

A restore is `pg_restore` into an empty database, then the normal startup: the migrate service
brings the schema up to date, which is a no-op when the dump is current.

Your tenants' virtual machines live in your OpenNebula zones and are not in scope here; OmniCP
holds the panel's own state.

---

## If something is wrong

- **The panel will not start** — run `./scripts/preflight.sh`. It catches most of it, and an
  `Invalid environment` on boot is almost always `PANEL_ENCRYPTION_KEY` not decoding to 32 bytes.
- **A region will not go `ACTIVE`** — the probe is the gate. `/admin/regions` shows what it
  returned.
- **`docker compose pull` is refused** — your registry token is the first thing to check, then
  that `OMNICP_VERSION` names a tag we actually published.
- **Anything else** — `/admin/status`, and send us the version line at the top of it.
