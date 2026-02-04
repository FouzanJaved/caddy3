#!/bin/bash
# ===============================================
# Fully Automated WordPress + Caddy + Reverse Proxy
# Supports ERP, Docs, Mail services
# Domain: sahmcore.com.sa
# ===============================================
set -e

# -------------------
# USER CONFIGURATION
# -------------------
DOMAIN="sahmcore.com.sa"
ADMIN_EMAIL="a.saeed@$DOMAIN"
WP_ADMIN_USER="admin"
WP_ADMIN_PASSWORD="Sahm2190"

# Internal VM IPs
THIS_VM_IP="192.168.116.37"
ERP_IP="192.168.116.13"
ERP_PORT="8069"
DOCS_IP="192.168.116.1"
DOCS_PORT="9443"
MAIL_IP="192.168.116.1"
MAIL_PORT="444"

# -------------------
# DETECT PRIMARY INTERFACE
# -------------------
PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
[ -z "$PRIMARY_IF" ] && PRIMARY_IF="eth0"

# -------------------
# SYSTEM UPDATE & DEPENDENCIES
# -------------------
echo "Updating system and installing dependencies..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget unzip lsb-release software-properties-common net-tools ufw dnsutils git mariadb-client mariadb-server

# -------------------
# PHP-FPM INSTALLATION
# -------------------
echo "Checking PHP-FPM..."
PHP_SOCKET=""
PHP_VERSION=""
if ! command -v php >/dev/null 2>&1; then
    echo "Installing latest PHP and PHP-FPM..."
    sudo add-apt-repository ppa:ondrej/php -y
    sudo apt update
    sudo apt install -y php php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-xmlrpc php-soap php-intl php-zip
fi

# Detect PHP version
PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
PHP_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
echo "Using PHP-FPM socket: $PHP_SOCKET"

# Ensure PHP-FPM is running
sudo systemctl enable --now php${PHP_VERSION}-fpm

# -------------------
# CADDY INSTALLATION
# -------------------
echo "Installing Caddy..."
if ! command -v caddy >/dev/null 2>&1; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt update
    sudo apt install -y caddy
fi

# -------------------
# STOP OTHER WEB SERVERS
# -------------------
sudo systemctl stop apache2 nginx 2>/dev/null || true
sudo systemctl disable apache2 nginx 2>/dev/null || true

# -------------------
# WORDPRESS INSTALLATION
# -------------------
WP_PATH="/var/www/html"
if [ ! -d "$WP_PATH" ]; then
    echo "Installing WordPress..."
    sudo mkdir -p $WP_PATH
    cd /tmp
    wget https://wordpress.org/latest.zip
    unzip -o latest.zip
    sudo mv wordpress/* $WP_PATH/
    sudo chown -R www-data:www-data $WP_PATH
fi

# Create wp-config.php if missing
WP_CONFIG="$WP_PATH/wp-config.php"
if [ ! -f "$WP_CONFIG" ]; then
    echo "Creating wp-config.php..."
    sudo cp "$WP_PATH/wp-config-sample.php" "$WP_CONFIG"
    sudo sed -i "s/database_name_here/wordpress_db/" $WP_CONFIG
    sudo sed -i "s/username_here/wordpress_user/" $WP_CONFIG
    sudo sed -i "s/password_here/wordpress_pass/" $WP_CONFIG
    sudo chown www-data:www-data $WP_CONFIG
    sudo chmod 640 $WP_CONFIG
fi

# Add reverse proxy support for HTTPS
if ! grep -q "HTTP_X_FORWARDED_PROTO" "$WP_CONFIG"; then
    sudo tee -a "$WP_CONFIG" > /dev/null << 'EOF'

// Reverse proxy support (HTTPS behind Caddy)
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
    $_SERVER['SERVER_PORT'] = 443;
}
if (isset($_SERVER['HTTP_X_FORWARDED_HOST'])) {
    $_SERVER['HTTP_HOST'] = $_SERVER['HTTP_X_FORWARDED_HOST'];
}

// Dynamic site URL
if (!defined('WP_SITEURL')) define('WP_SITEURL', 'https://' . $_SERVER['HTTP_HOST']);
if (!defined('WP_HOME')) define('WP_HOME', 'https://' . $_SERVER['HTTP_HOST']);
EOF
fi

# -------------------
# CREATE CADDYFILE
# -------------------
echo "Creating Caddyfile..."
sudo tee /etc/caddy/Caddyfile > /dev/null << EOF
# WordPress site
$DOMAIN, www.$DOMAIN {
    root * $WP_PATH
    php_fastcgi unix:$PHP_SOCKET
    file_server
    encode gzip zstd
    log {
        output file /var/log/caddy/wordpress.log
    }
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}

# ERP
erp.$DOMAIN {
    reverse_proxy http://$ERP_IP:$ERP_PORT {
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote}
    }
    log {
        output file /var/log/caddy/erp.log
    }
}

# Documentation
docs.$DOMAIN {
    reverse_proxy https://$DOCS_IP:$DOCS_PORT {
        transport http {
            tls_insecure_skip_verify
        }
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote}
    }
    log {
        output file /var/log/caddy/docs.log
    }
}

# Mail
mail.$DOMAIN {
    reverse_proxy http://$MAIL_IP:$MAIL_PORT {
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote}
    }
    log {
        output file /var/log/caddy/mail.log
    }
}

# Redirect HTTP to HTTPS
http://$DOMAIN, http://www.$DOMAIN, http://erp.$DOMAIN, http://docs.$DOMAIN, http://mail.$DOMAIN {
    redir https://{host}{uri} permanent
}
EOF

# -------------------
# FIREWALL SETUP
# -------------------
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable

# -------------------
# PERMISSIONS
# -------------------
sudo chown -R www-data:www-data $WP_PATH
sudo find $WP_PATH -type d -exec chmod 755 {} \;
sudo find $WP_PATH -type f -exec chmod 644 {} \;

# -------------------
# START SERVICES
# -------------------
sudo systemctl daemon-reload
sudo systemctl enable --now caddy

# -------------------
# COMPLETE
# -------------------
echo ""
echo "==============================================="
echo "SETUP COMPLETE!"
echo "WordPress should now be available at https://$DOMAIN"
echo "ERP: https://erp.$DOMAIN"
echo "Docs: https://docs.$DOMAIN"
echo "Mail: https://mail.$DOMAIN"
echo "WordPress default admin: $WP_ADMIN_USER / $WP_ADMIN_PASSWORD"
echo "Caddy + HTTPS should be fully functional"
echo "==============================================="
