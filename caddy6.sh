#!/bin/bash
# WordPress + Caddy automated deployment for sahmcore.com.sa
# Detects and installs dependencies, configures PHP-FPM, WordPress, and reverse proxy
# Fully redeployable on a new VM

set -e

DOMAIN="sahmcore.com.sa"
THIS_VM_IP="192.168.116.37"
GATEWAY_IP="192.168.116.1"
ADMIN_EMAIL="a.saeed@$DOMAIN"

# Subdomain targets
ERP_IP="192.168.116.13"
ERP_PORT=8069
DOCS_IP="192.168.116.1"
DOCS_PORT=9443
MAIL_IP="192.168.116.1"
MAIL_PORT=444

echo "==============================================="
echo "  WordPress + Caddy Automated Deployment"
echo "  Domain: $DOMAIN"
echo "  This VM: $THIS_VM_IP"
echo "==============================================="

read -p "Press Enter to continue..."

# Detect primary network interface
PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
PRIMARY_IF=${PRIMARY_IF:-eth0}
echo "Primary interface: $PRIMARY_IF"

# Step 1: Update system
echo "Updating system..."
sudo apt update && sudo apt upgrade -y

# Step 2: Install required packages
REQUIRED_PKGS=(curl wget net-tools ufw dnsutils unzip git mariadb-server php-cli php-mysql php-curl php-gd php-mbstring php-xml php-xmlrpc)
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -l | grep -qw $pkg; then
        echo "Installing missing package: $pkg"
        sudo apt install -y $pkg
    fi
done

# Step 3: Detect PHP-FPM service
PHP_FPM_SERVICE=""
for v in 8.2 8.1 8.0 7.4; do
    if systemctl list-unit-files | grep -q "php$v-fpm.service"; then
        PHP_FPM_SERVICE="php$v-fpm"
        break
    fi
done

if [ -z "$PHP_FPM_SERVICE" ]; then
    echo "No PHP-FPM found, installing php8.1-fpm..."
    sudo apt install -y php8.1-fpm
    PHP_FPM_SERVICE="php8.1-fpm"
fi

echo "Using PHP-FPM service: $PHP_FPM_SERVICE"

# Enable and start PHP-FPM
sudo systemctl enable --now $PHP_FPM_SERVICE

# Detect PHP-FPM socket
PHP_SOCKET=$(find /run/php -name "*fpm.sock" | head -1)
echo "PHP-FPM socket: $PHP_SOCKET"

# Step 4: Install Caddy
if ! command -v caddy &> /dev/null; then
    echo "Installing Caddy..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt update
    sudo apt install caddy -y
fi

# Step 5: Stop Apache/Nginx if running
for svc in apache2 nginx; do
    if systemctl is-active --quiet $svc; then
        sudo systemctl stop $svc
        sudo systemctl disable $svc
    fi
done

# Step 6: Install WordPress if missing
WP_PATH="/var/www/html"
if [ ! -d "$WP_PATH/wp-admin" ]; then
    echo "Installing WordPress..."
    wget https://wordpress.org/latest.zip -O /tmp/wordpress.zip
    unzip /tmp/wordpress.zip -d /tmp/
    sudo mkdir -p $WP_PATH
    sudo rsync -a /tmp/wordpress/ $WP_PATH/
    sudo chown -R www-data:www-data $WP_PATH
fi

# Step 7: Configure WordPress wp-config.php
DB_NAME="wordpress"
DB_USER="wpuser"
DB_PASS="wp_pass_$(openssl rand -hex 6)"

# Create database and user if not exist
sudo mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
sudo mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
sudo mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

WP_CONFIG="$WP_PATH/wp-config.php"
if [ ! -f "$WP_CONFIG" ]; then
    cp $WP_PATH/wp-config-sample.php $WP_CONFIG
    sed -i "s/database_name_here/$DB_NAME/" $WP_CONFIG
    sed -i "s/username_here/$DB_USER/" $WP_CONFIG
    sed -i "s/password_here/$DB_PASS/" $WP_CONFIG
    # Reverse proxy support
    cat <<'EOF' >> $WP_CONFIG

// Reverse proxy support
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] == 'https') {
    $_SERVER['HTTPS'] = 'on';
    $_SERVER['SERVER_PORT'] = 443;
}
if (isset($_SERVER['HTTP_X_FORWARDED_HOST'])) {
    $_SERVER['HTTP_HOST'] = $_SERVER['HTTP_X_FORWARDED_HOST'];
}
EOF
fi

sudo chown -R www-data:www-data $WP_PATH
sudo find $WP_PATH -type d -exec chmod 755 {} \;
sudo find $WP_PATH -type f -exec chmod 644 {} \;

# Step 8: Create Caddyfile
CADDYFILE="/etc/caddy/Caddyfile"
sudo tee $CADDYFILE > /dev/null <<EOF
{
    email $ADMIN_EMAIL
}

$DOMAIN, www.$DOMAIN {
    root * $WP_PATH
    php_fastcgi unix:$PHP_SOCKET {
        split .php
        index index.php
    }
    file_server
    try_files {path} {path}/ /index.php?{query}
    encode gzip
}

erp.$DOMAIN {
    reverse_proxy http://$ERP_IP:$ERP_PORT
}

docs.$DOMAIN {
    reverse_proxy http://$DOCS_IP:$DOCS_PORT
}

mail.$DOMAIN {
    reverse_proxy http://$MAIL_IP:$MAIL_PORT
}

http://$DOMAIN, http://www.$DOMAIN, http://erp.$DOMAIN, http://docs.$DOMAIN, http://mail.$DOMAIN {
    redir https://{host}{uri} permanent
}
EOF

# Step 9: Enable firewall
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow from 192.168.116.0/24
echo "y" | sudo ufw enable

# Step 10: Start and enable Caddy
sudo systemctl enable --now caddy
sudo caddy validate --config $CADDYFILE

# Step 11: Completion
echo "==============================================="
echo "Deployment complete!"
echo "WordPress path: $WP_PATH"
echo "PHP-FPM socket: $PHP_SOCKET"
echo "Caddy service running: $(systemctl is-active caddy)"
echo "Visit https://$DOMAIN to finish WordPress setup"
echo "Database: $DB_NAME / $DB_USER / $DB_PASS"
echo "==============================================="
