# Cloudflare Tunnel Setup Guide

This guide walks you through setting up a Cloudflare Tunnel to securely expose your n8n instance to the internet without opening ports on your router/firewall.

## Prerequisites

- A Cloudflare account (free tier works)
- A domain managed by Cloudflare DNS
- Docker and Docker Compose installed on your server
- This repository cloned and `.env` configured

## Benefits of Cloudflare Tunnel

- **No open ports**: Your server doesn't expose any ports to the internet
- **Built-in DDoS protection**: Cloudflare handles attacks at the edge
- **Automatic TLS**: No certificate management required
- **Hides origin IP**: Your home IP isn't exposed in DNS records
- **Zero Trust ready**: Can add authentication via Cloudflare Access

## Step 1: Add Your Domain to Cloudflare

If your domain isn't already on Cloudflare:

1. Log in to [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. Click **Add a Site**
3. Enter your domain name (e.g., `cogs.io`)
4. Select the **Free** plan (or higher)
5. Cloudflare will scan your existing DNS records
6. Update your domain registrar's nameservers to Cloudflare's nameservers
7. Wait for DNS propagation (can take up to 24 hours)

## Step 2: Create a Cloudflare Tunnel

1. Go to [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/)
   - You may need to set up Zero Trust if this is your first time
2. In the left sidebar, navigate to **Networks** > **Tunnels**
3. Click **Create a tunnel**
4. Select **Cloudflared** as the connector type
5. Name your tunnel (e.g., `n8n-home-server`)
6. Click **Save tunnel**

## Step 3: Get Your Tunnel Token

After creating the tunnel, you'll see an installation page:

1. Select the **Docker** tab
2. You'll see a command like:
   ```bash
   docker run cloudflare/cloudflared:latest tunnel --no-autoupdate run --token eyJhIjo...
   ```
3. Copy the token (the long string starting with `eyJ...`)
4. Add this token to your `.env` file:
   ```bash
   CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoiNjk...your-full-token-here
   ```

## Step 4: Configure Public Hostname

Still in the tunnel configuration:

1. Click on the **Public Hostname** tab
2. Click **Add a public hostname**
3. Configure the hostname:

   | Field | Value |
   |-------|-------|
   | Subdomain | `n8n` (or your chosen subdomain) |
   | Domain | Select your domain from the dropdown |
   | Type | `HTTP` |
   | URL | `n8n:5678` |

   > **Important**: Use `n8n:5678` (the Docker service name), NOT `localhost:5678`. The cloudflared container connects to n8n via the Docker network.

4. Click **Save hostname**

### Optional: Additional Settings

Under **Additional application settings** > **TLS**:
- **No TLS Verify**: Leave disabled (n8n serves HTTP, Cloudflare handles HTTPS)

Under **Additional application settings** > **HTTP Settings**:
- **HTTP Host Header**: Leave blank (uses the public hostname)

## Step 5: Start the Services

```bash
# Navigate to your n8n-compose directory
cd /path/to/n8n-compose

# Start all services
docker compose up -d

# Check that cloudflared connected successfully
docker compose logs cloudflared
```

You should see output like:
```
cloudflared  | 2025-01-01T00:00:00Z INF Connection registered connIndex=0 ...
cloudflared  | 2025-01-01T00:00:00Z INF Connection registered connIndex=1 ...
```

## Step 6: Verify Access

1. Open `https://n8n.yourdomain.com` in your browser
2. You should see the n8n setup/login page
3. Complete the n8n initial setup if this is a fresh installation

## Optional: Add Cloudflare Access Authentication

For additional security, you can require authentication before users can access n8n:

1. In Zero Trust Dashboard, go to **Access** > **Applications**
2. Click **Add an application**
3. Select **Self-hosted**
4. Configure:
   - **Application name**: `n8n`
   - **Session Duration**: Choose your preference
   - **Application domain**: `n8n.yourdomain.com`
5. Add an **Access Policy**:
   - **Policy name**: `Allowed Users`
   - **Action**: Allow
   - **Include**: Emails ending in `@yourdomain.com` (or specific email addresses)
6. Save the application

Now users will need to authenticate via Cloudflare before accessing n8n.

## Troubleshooting

### Tunnel Not Connecting

**Check the logs:**
```bash
docker compose logs cloudflared
```

**Common issues:**

1. **Invalid token**: Verify `CLOUDFLARE_TUNNEL_TOKEN` in `.env` is correct (no extra spaces or newlines)

2. **Network issues**: Ensure your server can reach Cloudflare:
   ```bash
   docker compose exec cloudflared ping -c 3 cloudflare.com
   ```

3. **Token expired**: Tokens can expire. Create a new tunnel or regenerate the token in the dashboard.

### 502 Bad Gateway

This means cloudflared can reach Cloudflare but can't connect to n8n:

1. **Check n8n is running:**
   ```bash
   docker compose ps
   ```

2. **Check n8n logs:**
   ```bash
   docker compose logs n8n
   ```

3. **Verify hostname URL**: In Cloudflare dashboard, ensure the URL is `n8n:5678` (not `localhost:5678`)

4. **Check network connectivity:**
   ```bash
   docker compose exec cloudflared wget -q -O- http://n8n:5678/healthz
   ```

### DNS Not Resolving

1. Verify the DNS record exists in Cloudflare dashboard
2. Check the tunnel status shows "Healthy" in Zero Trust dashboard
3. DNS propagation can take a few minutes
4. Try flushing your local DNS cache

### Webhooks Not Working

Webhooks should work automatically through the tunnel. If they're not:

1. Verify `WEBHOOK_URL` in `.env` is set correctly:
   ```bash
   WEBHOOK_URL=https://n8n.yourdomain.com/
   ```

2. Check that the workflow webhook URL matches your domain

3. Test with a simple webhook site like webhook.site

## Security Best Practices

1. **Keep your tunnel token secret**: Never commit `.env` to git
2. **Use Cloudflare Access**: Add an authentication layer
3. **Enable n8n authentication**: Set up user accounts in n8n
4. **Monitor tunnel status**: Check Zero Trust dashboard periodically
5. **Keep images updated**: Use the update.sh script regularly

## Updating Cloudflared

When a new version is available:

1. Update the version in `compose.yaml`
2. Pull the new image:
   ```bash
   docker compose pull cloudflared
   ```
3. Restart the service:
   ```bash
   docker compose up -d cloudflared
   ```

Or use the provided update script:
```bash
./update.sh --apply
```

## Useful Commands

```bash
# View tunnel status
docker compose logs -f cloudflared

# Restart tunnel
docker compose restart cloudflared

# Check all services
docker compose ps

# View n8n through tunnel
curl -I https://n8n.yourdomain.com
```

## Resources

- [Cloudflare Tunnel Documentation](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)
- [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/)
- [n8n Documentation](https://docs.n8n.io/)
