#!/bin/bash
set -e

echo "==============================================="
echo "  Caddy + WordPress Reverse Proxy Setup"
echo "  Domain: sahmcore.com.sa"
echo "==============================================="

DOMAIN="sahmcore.com.sa"
EMAIL="a.saeed@sahmcore.com.sa"

ODOO_IP="192.168.116.13"
ODOO_PORT="8069"

DOCS_IP="192.168.116.1"
DOCS_PORT="9443"

MAIL_IP="192.168.116.1"
MAIL_PORT="444"

WP_ROOT="/var/www/html"

echo "[1/7] Updating system"
sudo apt update -y
sudo apt install -y curl wget ca-certificates gnupg lsb-release ufw

echo "[2/7] Installing Caddy (official repo)"
if ! command -v caddy >/dev/null; then
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
        | sudo gpg --dearmor -o /usr/share/keyrings/caddy.gpg

    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
        | sudo tee /etc/apt/sources.list.d/caddy.list

    sudo apt update -y
    sudo apt install -y caddy
fi

echo "[3/7] Stopping legacy web servers (if any)"
sudo systemctl stop apache2 nginx 2>/dev/null || true
sudo systemctl disable apache2 nginx 2>/dev/null || true

echo "[4/7] Detecting PHP-FPM socket"
PHP_SOCKET=$(find /run/php -name "php*-fpm.sock" | head -1 || true)

if [ -z "$PHP_SOCKET" ]; then
    echo "ERROR: PHP-FPM socket not found."
    echo "Install PHP-FPM first (php8.x-fpm)."
    exit 1
fi

echo "✔ Using PHP socket: $PHP_SOCKET"

echo "[5/7] Writing Caddyfile"
sudo tee /etc/caddy/Caddyfile > /dev/null <<EOF
{
    email $EMAIL
    admin off

    log {
        output file /var/log/caddy/access.log {
            roll_size 100mb
            roll_keep 5
        }
        level INFO
    }
}

$DOMAIN, www.$DOMAIN {
    root * $WP_ROOT
    encode gzip zstd

    php_fastcgi unix//$PHP_SOCKET
    file_server

    try_files {path} {path}/ /index.php?{query}

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }

    log {
        output file /var/log/caddy/wordpress.log
    }
}

erp.$DOMAIN {
    reverse_proxy http://$ODOO_IP:$ODOO_PORT {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }

    log {
        output file /var/log/caddy/erp.log
    }
}

docs.$DOMAIN {
    reverse_proxy https://$DOCS_IP:$DOCS_PORT {
        transport http {
            tls_insecure_skip_verify
        }
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
    }

    log {
        output file /var/log/caddy/docs.log
    }
}

mail.$DOMAIN {
    reverse_proxy http://$MAIL_IP:$MAIL_PORT {
        header_up Host {host}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
        header_up Connection {>Connection}
        header_up Upgrade {>Upgrade}
    }

    log {
        output file /var/log/caddy/mail.log
    }
}

health.$DOMAIN {
    respond "OK" 200
    header Content-Type text/plain
}

*.$DOMAIN {
    redir https://$DOMAIN{uri}
}
EOF

echo "[6/7] Validating Caddy configuration"
sudo caddy validate --config /etc/caddy/Caddyfile

echo "[7/7] Enabling firewall (safe rules only)"
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

echo "Reloading Caddy"
sudo systemctl reload caddy
sudo systemctl enable caddy

echo "==============================================="
echo " SETUP COMPLETE"
echo "==============================================="
echo ""
echo "URLs:"
echo "  https://$DOMAIN"
echo "  https://erp.$DOMAIN"
echo "  https://docs.$DOMAIN"
echo "  https://mail.$DOMAIN"
echo ""
echo "Check logs:"
echo "  journalctl -u caddy -f"
