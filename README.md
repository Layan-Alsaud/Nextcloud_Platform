# Nextcloud Collaboration Platform on Azure

An internal file-sharing and collaboration platform built on Nextcloud, provisioned on Microsoft Azure with Terraform and deployed via Docker Compose, with Bash automation handling setup, configuration, and health checks.

## Repository structure

01_data/ Sample from the workflow demo
02_src/
terraform-stack/ Infrastructure as code (Azure resource group, VNet, NSG, VM)
nextcloud-stack/ Application deployment (Docker Compose stack + automation)
03_assets/ Screenshots 
requirements.txt Dependency note: no Python dependencies


## Architecture

- **Azure VM**, provisioned by Terraform: resource group, virtual network/subnet,
  network security group, public IP, and the VM itself.
- **Docker Compose stack** running on the VM:
  - `db` — PostgreSQL 18 (Alpine)
  - `redis` — Redis 7, used for caching and file locking
  - `app` — Nextcloud 29 (Apache)
  - `caddy` — reverse proxy in front of Nextcloud (see "HTTPS" below)
- **`deploy.sh`** — idempotent Bash automation: installs Docker if missing,
  bootstraps `.env` with randomly generated secrets, auto-detects the VM's
  public IP, renders the Caddy configuration, starts the stack, and waits for
  a health check before finishing. Safe to re-run any time (after a reboot,
  an IP change, or a full `terraform destroy`/`apply` cycle) — verified for
  both idempotent re-runs and true fresh installs.

## Prerequisites

- An Azure subscription and credentials Terraform's `azurerm` provider can use
- [Terraform](https://developer.hashicorp.com/terraform/install)
- An SSH key pair (a path to both halves is set in `variables.tf`)
- Your own machine's public IPv4 address (used to restrict SSH access — see
  "Security" below)

## Setup — Part 1: Provision the infrastructure

```bash
cd 02_src/terraform
cp terraform.tfvars.example terraform.tfvars
```

Find your current public IPv4 address:
```bash
curl -4 ifconfig.me
```
Edit `terraform.tfvars` and set `admin_source_ip` to that address in `/32`
CIDR form (e.g. `"203.0.113.45/32"`).

```bash
terraform init
terraform plan
terraform apply
```

Note: the `public_ip_address` output — It is the VM's address for every step
below.

## Setup — Part 2: Deploy the Nextcloud stack

From `02_src/nextcloud-stack/`:
```bash
scp -i /path/to/your/key.pem docker-compose.yml .env.example deploy.sh Caddyfile.template \
    azureuser@<VM_PUBLIC_IP>:~/nextcloud/
ssh -i /path/to/your/key.pem azureuser@<VM_PUBLIC_IP>
cd ~/nextcloud
chmod +x deploy.sh
./deploy.sh
```

`deploy.sh` handles everything from here: Docker installation, `.env`
generation with strong random secrets, Caddy configuration, starting the
stack, and a health check against Nextcloud's own status endpoint. When it
finishes, open `http://<VM_PUBLIC_IP>/` in a browser and log in with the
admin credentials it generated (`NEXTCLOUD_ADMIN_USER`/
`NEXTCLOUD_ADMIN_PASSWORD` in the VM's `.env`, valid only for the very first
install and not kept in sync afterward; to reset the password later, run `docker compose exec -u www-data app php occ user:resetpassword <username>` on the VM).

## Security considerations

- **Network access control:** the NSG opens only ports 22, 80, and 443,
  Azure denies everything else by default. SSH (22) is further restricted to
  a single administrator IP via the `admin_source_ip` Terraform variable,
  rather than being open to the entire internet. HTTP/HTTPS (80/443) are
  deliberately left open, since this platform is meant to be reached by an
  entire internal team from wherever they are, protected by Nextcloud's own
  authentication rather than network-level source restriction.
- **Caddy (reverse proxy):** Caddy sits in front of the Nextcloud app
  container and handles all incoming traffic on port 80, forwarding
  requests to Nextcloud's internal web server. `deploy.sh` renders
  `Caddyfile.template` into the live `Caddyfile` on each run, filling in
  the VM's current public IP automatically, so the proxy config doesn't
  need to be hand-edited when the IP changes. This gives the stack a single,
  stable entry point and keeps the reverse-proxy configuration separate from Nextcloud's own settings.
- **Secrets management:** `.env` (holding live database/admin/Redis
  passwords) is never committed or shipped — only `.env.example`, a
  placeholder template, is included. `deploy.sh` generates strong random
  secrets automatically on first run.
- **User and group access control:** internal departments are modeled as Nextcloud groups (e.g. Management, Engineering & IT, Sales & Marketing), each with its own shared folder. Where a department manager needs to manage their team's  accounts, they are granted "administered groups" rights over *only their own* department's group, following the principle of least privilege, rather than granting broad administrative rights across departments.

## Repeatability

Two levels of verification were performed:
1. **Isolated fresh-install test** — `deploy.sh` run against a completely
   empty state (no existing `.env`/`Caddyfile`) in a throwaway directory,
   confirming the entire bootstrap path works correctly, independent of the
   real deployment's data.
2. **Full infrastructure repeatability test** — `terraform destroy` followed
   by `terraform apply` and `deploy.sh`, confirming the platform can be
   completely torn down and rebuilt from code alone.

## Workflow demonstration

The platform was populated with a realistic internal structure: 4 departments
(as Nextcloud groups) and 11 demo users, each department with its own shared
folder (edit permission granted to its group). The demonstrated workflow
covers every stage in the brief's example scenario: uploading files into
department folders, live multi-user collaborative editing via Nextcloud's
built-in Text app, review via inline comments, and version history for
tracking and restoring prior file versions. See `03_assets/` for screenshots
of each stage and `01_data/` for sample documents used in the demo.


## Troubleshooting

- `app` container unhealthy or restarting: check `docker compose logs app`,
  and confirm `db` is healthy first (`docker compose logs db`).
- Connection refused from a browser: check the Azure NSG allows inbound
  port 80 from your IP.
- "Access through untrusted domain" error: the VM's public IP doesn't
  match `NEXTCLOUD_TRUSTED_DOMAINS` in `.env` — `deploy.sh` re-syncs this
  automatically against the VM's current public IP on every run.
- Forgot the admin password: reset it with
  `docker compose exec -u www-data app php occ user:resetpassword <username>`.