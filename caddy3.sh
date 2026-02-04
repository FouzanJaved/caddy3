{
    email a.saeed@sahmcore.com.sa
    admin off

    log {
        output file /var/log/caddy/access.log {
            roll_size 100mb
            roll_keep 5
        }
        level INFO
    }

    servers {
        protocols h1 h2 h3
    }
}

# --------------------------------------------------
# Main Website – WordPress
# --------------------------------------------------
sahmcore.com.sa, www.sahmcore.com.sa {

    root * /var/www/html
    encode gzip zstd

    php_fastcgi unix//run/php/php8.1-fpm.sock
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

# --------------------------------------------------
# ERP – Odoo
# --------------------------------------------------
erp.sahmcore.com.sa {

    reverse_proxy http://192.168.116.13:8069 {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }

    log {
        output file /var/log/caddy/erp.log
    }
}

# --------------------------------------------------
# Documentation Server (HTTPS backend)
# --------------------------------------------------
docs.sahmcore.com.sa {

    reverse_proxy https://192.168.116.1:9443 {
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

# --------------------------------------------------
# Mail Web Interface
# --------------------------------------------------
mail.sahmcore.com.sa {

    reverse_proxy http://192.168.116.1:444 {
        header_up Host {host}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}

        # WebSocket support (safe even if unused)
        header_up Connection {>Connection}
        header_up Upgrade {>Upgrade}
    }

    log {
        output file /var/log/caddy/mail.log
    }
}

# --------------------------------------------------
# Health Check
# --------------------------------------------------
health.sahmcore.com.sa {
    respond "OK" 200
    header Content-Type text/plain
}

# --------------------------------------------------
# Catch-all Subdomains
# --------------------------------------------------
*.sahmcore.com.sa {
    redir https://sahmcore.com.sa{uri}
}
