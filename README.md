# n8n-compose

A production-ready Docker Compose deployment for [n8n](https://n8n.io/) workflow automation with PostgreSQL database and Cloudflare Tunnel for secure external access.

## Features

- **n8n 2.x** - Latest workflow automation platform
- **PostgreSQL 16** - Reliable database backend
- **Cloudflare Tunnel** - Secure external access without opening ports
- **No exposed ports** - Your home IP stays hidden
- **Automated backups** - Scripts for backup and restore
- **Auto-updates** - Dependabot monitors for new versions
- **GitHub Actions** - Automated releases when dependencies update

## Architecture

```
Internet → Cloudflare Edge → cloudflared → n8n (5678) → PostgreSQL (5432)
```

All traffic flows through Cloudflare's network. No ports need to be opened on your router/firewall.

## Prerequisites

- Docker and Docker Compose installed
- A domain managed by Cloudflare DNS
- A Cloudflare account (free tier works)

## Getting Started

### 1. Clone the Repository

```bash
git clone https://github.com/cognitivegears/n8n-compose.git
cd n8n-compose
```

### 2. Configure Environment

```bash
cp .env.example .env
```

Edit `.env` with your values:

```bash
# Your domain configuration
DOMAIN_NAME=example.com
SUBDOMAIN=n8n

# Generate strong passwords for PostgreSQL
POSTGRES_PASSWORD=your-secure-password
POSTGRES_NON_ROOT_PASSWORD=another-secure-password

# Cloudflare Tunnel token (see next step)
CLOUDFLARE_TUNNEL_TOKEN=your-tunnel-token
```

### 3. Set Up Cloudflare Tunnel

Follow the detailed guide: **[CLOUDFLARE_SETUP.md](CLOUDFLARE_SETUP.md)**

Quick summary:
1. Go to [Cloudflare Zero Trust](https://one.dash.cloudflare.com/)
2. Navigate to **Networks** → **Tunnels**
3. Create a tunnel and copy the token
4. Add the token to your `.env` file
5. Configure the public hostname to point to `n8n:5678`

### 4. Start the Services

```bash
docker compose up -d
```

### 5. Verify Deployment

```bash
# Check all services are running
docker compose ps

# View logs
docker compose logs -f

# Check tunnel connection
docker compose logs cloudflared
```

Your n8n instance should now be available at `https://n8n.yourdomain.com`

## Usage

### Common Commands

```bash
# Start all services
docker compose up -d

# Stop all services
docker compose down

# View logs
docker compose logs -f [service]  # service: n8n, postgres, cloudflared

# Restart a specific service
docker compose restart [service]
```

### Backup and Restore

```bash
# Create a backup
./backup.sh

# List available backups
ls -la backups/

# Restore from backup
./restore.sh backups/backup-YYYYMMDD-HHMMSS.tar.gz
```

Backups include:
- PostgreSQL database dump
- n8n data volume (workflows, credentials, settings)
- Configuration files

### Automated Backups

Add to crontab for daily backups at 2 AM:

```bash
crontab -e
```

```cron
0 2 * * * /path/to/n8n-compose/backup.sh >> /var/log/n8n-backup.log 2>&1
```

### Updating

Check for and apply updates from GitHub releases:

```bash
# Check for updates
./update.sh --check

# Apply updates (creates backup first)
./update.sh --apply
```

## Image Versions

Images are pinned for stability:

| Image | Version |
|-------|---------|
| PostgreSQL | 16.11 |
| n8n | 2.1.4 |
| cloudflared | 2025.11.1 |

Dependabot automatically checks for updates weekly and creates pull requests.

## File Structure

```
n8n-compose/
├── compose.yaml          # Docker Compose configuration
├── .env                  # Environment variables (not in git)
├── .env.example          # Template for .env
├── init-data.sh          # PostgreSQL initialization script
├── backup.sh             # Backup script
├── restore.sh            # Restore script
├── update.sh             # Update script
├── CLOUDFLARE_SETUP.md   # Cloudflare Tunnel setup guide
├── CLAUDE.md             # Claude Code project instructions
├── README.md             # This file
├── LICENSE               # GPL-3.0 license
└── .github/
    ├── dependabot.yml    # Dependabot configuration
    └── workflows/
        ├── release.yml   # Auto-release workflow
        └── validate.yml  # PR validation workflow
```

## Local Access

n8n is also available locally at `http://127.0.0.1:5678` for direct access without going through Cloudflare.

## Security Considerations

- **Secrets**: All secrets are stored in `.env` which is excluded from git
- **No open ports**: Cloudflare Tunnel creates outbound-only connections
- **DDoS protection**: Cloudflare handles attacks at the edge
- **Optional authentication**: Add Cloudflare Access for additional auth layer

## Troubleshooting

### Tunnel Not Connecting

```bash
docker compose logs cloudflared
```

- Verify `CLOUDFLARE_TUNNEL_TOKEN` in `.env`
- Check your internet connection
- Ensure the tunnel exists in Cloudflare dashboard

### 502 Bad Gateway

- Check if n8n is running: `docker compose ps`
- View n8n logs: `docker compose logs n8n`
- Verify hostname URL is `n8n:5678` in Cloudflare (not `localhost`)

### Database Connection Issues

```bash
docker compose logs postgres
```

- Ensure PostgreSQL is healthy: `docker compose ps`
- Check credentials match between `.env` and n8n configuration

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [n8n](https://n8n.io/) - Workflow automation platform
- [Cloudflare](https://www.cloudflare.com/) - Tunnel and edge services
- [PostgreSQL](https://www.postgresql.org/) - Database
