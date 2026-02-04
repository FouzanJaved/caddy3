#!/bin/bash
set -e

############################################
# CONFIGURATION
############################################
DOMAIN="sahmcore.com.sa"
EMAIL="a.saeed@sahmcore.com.sa"

ODOO_IP="192.168.116.13"
ODOO_PORT="8069"

DOCS_IP="192.168.116.1"
DOCS_PORT="9443"

MAIL_IP="192.168.116.1"
MAIL_PORT="444"

WP_ROOT="/var/www/html"

# WordPress DB config
DB_NAME="wp_sahmcore"
DB_USER="wp_user"
DB_PASS="ChangeMe123!"   # change for production
DB_HOST="localhost"

############################################
# PRE-FLIGHT
############################################
echo "=== Sahmcore Auto Deployment with WordPress ==="
echo "Domain: $DOMAIN"
echo "Email:  $EMAIL"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo bash deploy-sahmcore.sh"
    exit 1
fi

############################################
# SYSTEM UPDATE
############################################
echo "[1/12] Updating system"
apt update -y && apt upgrade -y

############################################
# INSTALL PHP + EXTENSIONS + MYSQL
############################################
echo "[2/12] Installing PHP-FPM + extensions + MariaDB"
apt install -y \
    php-fpm php-cli php-mysql php-curl php-gd \
    php-mbstring php-xml php-zip php-opcache \
    mariadb-server curl unzip

systemctl enable --now php*-fpm
systemctl enable --now mariadb

############################################
# CREATE WP DATABASE
############################################
echo "[3/12] Creating WordPress database and user"
mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

############################################
# INSTALL CADDY
############################################
echo "[4/12] Installing Caddy"
if ! command -v caddy >/dev/null; then
    apt install -y curl ca-certificates gnupg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/caddy.gpg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
        | tee /etc/apt/sources.list.d/caddy.list
    apt update -y
    apt install -y caddy
fi

############################################
# DISABLE APACHE / NGINX
############################################
echo "[5/12] Disabling Apache/Nginx"
systemctl stop apache2 nginx 2>/dev/null || true
systemctl disable apache2 nginx 2>/dev/null || true

############################################
# DOWNLOAD WORDPRESS
############################################
echo "[6/12] Downloading WordPress"
mkdir -p "$WP_ROOT"
cd /tmp
curl -LO https://wordpress.org/latest.zip
unzip -o latest.zip
cp -r wordpress/* "$WP_ROOT/"
chown -R www-data:www-data "$WP_ROOT"
rm -rf /tmp/wordpress latest.zip

############################################
# CREATE WP CONFIG
############################################
echo "[7/12] Creating wp-config.php"
WP_CONFIG="$WP_ROOT/wp-config.php"
cp "$WP_ROOT/wp-config-sample.php" "$WP_CONFIG"

sed -i "s/database_name_here/$DB_NAME/" "$WP_CONFIG"
sed -i "s/username_here/$DB_USER/" "$WP_CONFIG"
sed -i "s/password_here/$DB_PASS/" "$WP_CONFIG"
sed -i "s/localhost/$DB_HOST/" "$WP_CONFIG"

# Add HTTPS proxy handling
cat <<'EOF' >> "$WP_CONFIG"

/* === CADDY_PROXY === */
if (
    isset($_SERVER['HTTP_X_FORWARDED_PROTO']) &&
    $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https'
) {
    $_SERVER['HTTPS'] = 'on';
    $_SERVER['SERVER_PORT'] = 443;
}

if (!empty($_SERVER['HTTP_X_FORWARDED_FOR'])) {
    $_SERVER['REMOTE_ADDR'] = explode(',', $_SERVER['HTTP_X_FORWARDED_FOR'])[0];
}

define('WP_HOME', 'https://' . $_SERVER['HTTP_HOST']);
define('WP_SITEURL', 'https://' . $_SERVER['HTTP_HOST']);
/* === END CADDY_PROXY === */
EOF

############################################
# PERMISSIONS
############################################
echo "[8/12] Fixing WordPress permissions"
chown -R www-data:www-data "$WP_ROOT"
find "$WP_ROOT" -type d -exec chmod 755 {} \;
find "$WP_ROOT" -type f -exec chmod 644 {} \;
chmod -R 775 "$WP_ROOT/wp-content" 2>/dev/null || true

############################################
# DETECT PHP SOCKET
############################################
PHP_SOCKET=$(find /run/php -name "php*-fpm.sock" | head -1)
if [ -z "$PHP_SOCKET" ]; then
    echo "ERROR: PHP-FPM socket not found"
    exit 1
fi
echo "Using PHP socket: $PHP_SOCKET"

############################################
# WRITE CADDYFILE
############################################
echo "[9/12] Writing Caddyfile"

cat <<EOF > /etc/caddy/Caddyfile
{
    email $EMAIL
    admin off
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
}

erp.$DOMAIN {
    reverse_proxy http://$ODOO_IP:$ODOO_PORT
}

docs.$DOMAIN {
    reverse_proxy https://$DOCS_IP:$DOCS_PORT {
        transport http {
            tls_insecure_skip_verify
        }
    }
}

mail.$DOMAIN {
    reverse_proxy http://$MAIL_IP:$MAIL_PORT {
        header_up Connection {>Connection}
        header_up Upgrade {>Upgrade}
    }
}

health.$DOMAIN {
    respond "OK" 200
}

*.$DOMAIN {
    redir https://$DOMAIN{uri}
}
EOF

############################################
# FIREWALL
############################################
echo "[10/12] Configuring firewall"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

############################################
# START SERVICES
############################################
echo "[11/12] Starting services"
caddy validate --config /etc/caddy/Caddyfile
systemctl enable caddy
systemctl reload caddy

############################################
# CLEANUP
############################################
echo "[12/12] Deployment complete"
echo ""
echo "WordPress URL: https://$DOMAIN"
echo "ERP URL:       https://erp.$DOMAIN"
echo "Docs URL:      https://docs.$DOMAIN"
echo "Mail URL:      https://mail.$DOMAIN"
echo ""
echo "WordPress DB:"
echo "  Name: $DB_NAME"
echo "  User: $DB_USER"
echo "  Pass: $DB_PASS"
echo ""
echo "Check logs: journalctl -u caddy -f"
