#!/bin/bash
set -e

echo "==============================================="
echo "  Full WordPress + Caddy Reverse Proxy Setup"
echo "  Using existing PHP 8.3-FPM"
echo "==============================================="

# --- CONFIGURATION ---
DOMAIN="sahmcore.com.sa"
ERP_IP="192.168.116.13"
ERP_PORT=8069
DOCS_IP="192.168.116.1"
DOCS_PORT=9443
MAIL_IP="192.168.116.1"
MAIL_PORT=444
ADMIN_EMAIL="a.saeed@$DOMAIN"
WP_PATH="/var/www/html"
BACKUP_DIR="/root/backup-$(date +%Y%m%d-%H%M%S)"

# --- BACKUP EXISTING CONFIGS ---
mkdir -p "$BACKUP_DIR"
cp -r /etc/apache2 "$BACKUP_DIR/apache2-backup" 2>/dev/null || true
cp -r /etc/nginx "$BACKUP_DIR/nginx-backup" 2>/dev/null || true
cp -r "$WP_PATH" "$BACKUP_DIR/html-backup" 2>/dev/null || true
cp /etc/hosts "$BACKUP_DIR/hosts-backup" 2>/dev/null || true
echo "Backup created at $BACKUP_DIR"

# --- UPDATE SYSTEM ---
apt update && apt upgrade -y

# --- INSTALL REQUIRED PACKAGES ---
REQUIRED_PKGS=(curl wget net-tools ufw dnsutils unzip git mariadb-server lsb-release gnupg software-properties-common)
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -l | grep -qw $pkg; then
        apt install -y $pkg
    fi
done

# --- INSTALL CADDY ---
if ! command -v caddy &>/dev/null; then
    echo "Installing Caddy..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt update
    apt install -y caddy
fi

# --- STOP OTHER WEB SERVERS ---
systemctl stop apache2 2>/dev/null || true
systemctl disable apache2 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true

# --- WORDPRESS INSTALL ---
if [ ! -f "$WP_PATH/wp-config.php" ]; then
    echo "Installing WordPress..."
    mkdir -p "$WP_PATH"
    cd /tmp
    wget https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz
    cp -r wordpress/* "$WP_PATH"
    chown -R www-data:www-data "$WP_PATH"
    find "$WP_PATH" -type d -exec chmod 755 {} \;
    find "$WP_PATH" -type f -exec chmod 644 {} \;

    # Create wp-config.php
    DB_NAME="wordpress"
    DB_USER="wpuser"
    DB_PASS="wp_password"
    mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
    mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
    mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    cp "$WP_PATH/wp-config-sample.php" "$WP_PATH/wp-config.php"
    sed -i "s/database_name_here/$DB_NAME/" "$WP_PATH/wp-config.php"
    sed -i "s/username_here/$DB_USER/" "$WP_PATH/wp-config.php"
    sed -i "s/password_here/$DB_PASS/" "$WP_PATH/wp-config.php"

    # Reverse proxy handling
    tee -a "$WP_PATH/wp-config.php" > /dev/null << 'EOF'

// Reverse proxy support
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO']=='https') {
    $_SERVER['HTTPS']='on';
}
if (isset($_SERVER['HTTP_X_FORWARDED_HOST'])) {
    $_SERVER['HTTP_HOST']=$_SERVER['HTTP_X_FORWARDED_HOST'];
}
EOF
fi

# --- DETECT PHP SOCKET ---
PHP_SOCKET=$(find /run/php -name 'php*-fpm.sock' | head -1)
if [ ! -S "$PHP_SOCKET" ]; then
    echo "PHP-FPM socket not found. Ensure PHP 8.3-FPM is running."
    exit 1
fi
echo "Using PHP socket: $PHP_SOCKET"

# --- CREATE CADDYFILE ---
tee /etc/caddy/Caddyfile > /dev/null << EOF
{
    email $ADMIN_EMAIL
    admin off
}

# WordPress
$DOMAIN, www.$DOMAIN {
    root * $WP_PATH
    php_fastcgi unix:$PHP_SOCKET
    file_server
    encode gzip zstd
    try_files {path} {path}/ /index.php?{query}
}

# ERP
erp.$DOMAIN {
    reverse_proxy http://$ERP_IP:$ERP_PORT
}

# Docs
docs.$DOMAIN {
    reverse_proxy http://$DOCS_IP:$DOCS_PORT
}

# Mail
mail.$DOMAIN {
    reverse_proxy http://$MAIL_IP:$MAIL_PORT
}

# HTTP redirect
http://$DOMAIN, http://www.$DOMAIN, http://erp.$DOMAIN, http://docs.$DOMAIN, http://mail.$DOMAIN {
    redir https://{host}{uri} permanent
}
EOF

# --- FIREWALL ---
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow from 192.168.116.0/24
echo "y" | ufw enable

# --- START SERVICES ---
systemctl daemon-reload
systemctl enable --now php8.3-fpm
systemctl enable --now mariadb
systemctl enable --now caddy

# --- FINAL CHECKS ---
echo "=== CHECKING SERVICES ==="
systemctl is-active php8.3-fpm && echo "PHP-FPM is running"
systemctl is-active mariadb && echo "MariaDB is running"
systemctl is-active caddy && echo "Caddy is running"
echo "WordPress path: $WP_PATH"
echo "Access your site at https://$DOMAIN"

echo "Setup complete! SSL will be issued automatically if DNS points to this VM."
