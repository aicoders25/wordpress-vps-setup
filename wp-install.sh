#!/bin/bash

# Automated WordPress Installation Script for Ubuntu 24.04 VPS with Nginx
# Version 1.0 - July 2025
# This script sets up a secure and fast WordPress site using LEMP stack.
# Run as root: sudo bash wp-install.sh
# Requirements: Fresh Ubuntu 24.04 VPS, domain pointed to server IP.

# Function to check if command succeeded
check_success() {
    if [ $? -ne 0 ]; then
        echo "Error: $1 failed. Exiting."
        exit 1
    fi
}

# Prompt for user inputs
read -p "Enter your domain name (e.g., example.com): " DOMAIN
read -p "Enter WordPress database name (default: wordpressdb): " DBNAME
DBNAME=${DBNAME:-wordpressdb}
read -p "Enter WordPress database user (default: wpuser): " DBUSER
DBUSER=${DBUSER:-wpuser}
read -s -p "Enter WordPress database password: " DBPASS
echo ""
read -p "Enter email for Let's Encrypt SSL: " EMAIL
read -p "Enter a new sudo username for security (default: adminuser): " NEWUSER
NEWUSER=${NEWUSER:-adminuser}
read -s -p "Enter password for new sudo user: " NEWUSERPASS
echo ""

# Update system
echo "Updating system..."
apt update -y && apt upgrade -y
check_success "System update"

# Install firewall and allow ports
echo "Setting up firewall..."
apt install ufw -y
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable
check_success "Firewall setup"

# Install Fail2Ban
echo "Installing Fail2Ban..."
apt install fail2ban -y
systemctl enable fail2ban
systemctl start fail2ban
check_success "Fail2Ban installation"

# Create new sudo user
echo "Creating new sudo user..."
adduser --disabled-password --gecos "" $NEWUSER
echo "$NEWUSER:$NEWUSERPASS" | chpasswd
usermod -aG sudo $NEWUSER
check_success "New user creation"

# Disable root SSH
sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart ssh
check_success "Root SSH disable"

# Install Nginx
echo "Installing Nginx..."
apt install nginx -y
systemctl start nginx
systemctl enable nginx
check_success "Nginx installation"

# Install MariaDB
echo "Installing MariaDB..."
apt install mariadb-server -y
systemctl start mariadb
systemctl enable mariadb
mysql_secure_installation <<EOF

y
$DBPASS
$DBPASS
y
y
y
y
EOF
check_success "MariaDB installation"

# Install PHP 8.3
echo "Installing PHP 8.3..."
apt install software-properties-common -y
add-apt-repository ppa:ondrej/php -y
apt update
apt install php8.3 php8.3-fpm php8.3-mysql php8.3-curl php8.3-gd php8.3-mbstring php8.3-xml php8.3-zip php8.3-intl php8.3-imap php8.3-snmp -y
systemctl start php8.3-fpm
systemctl enable php8.3-fpm
check_success "PHP installation"

# Optimize PHP
sed -i 's/memory_limit = .*/memory_limit = 256M/' /etc/php/8.3/fpm/php.ini
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 64M/' /etc/php/8.3/fpm/php.ini
sed -i 's/post_max_size = .*/post_max_size = 64M/' /etc/php/8.3/fpm/php.ini
systemctl restart php8.3-fpm
check_success "PHP optimization"

# Create database
echo "Creating database..."
mysql -u root -p$DBPASS <<EOF
CREATE DATABASE $DBNAME;
CREATE USER '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS';
GRANT ALL PRIVILEGES ON $DBNAME.* TO '$DBUSER'@'localhost';
FLUSH PRIVILEGES;
EOF
check_success "Database creation"

# Download WordPress
echo "Downloading WordPress..."
cd /var/www/html
wget https://wordpress.org/latest.tar.gz
tar -xvzf latest.tar.gz
mv wordpress/* .
rm -rf wordpress latest.tar.gz
chown -R www-data:www-data /var/www/html/
chmod -R 755 /var/www/html/
check_success "WordPress download"

# Configure wp-config.php
cp wp-config-sample.php wp-config.php
sed -i "s/database_name_here/$DBNAME/" wp-config.php
sed -i "s/username_here/$DBUSER/" wp-config.php
sed -i "s/password_here/$DBPASS/" wp-config.php

# Fetch salts
SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
echo "$SALTS" > salts.txt
sed -i '/put your unique phrase here/d' wp-config.php
awk '/AUTH_KEY/ { system("cat salts.txt") } !/AUTH_KEY/' wp-config.php > temp && mv temp wp-config.php
rm salts.txt
check_success "wp-config setup"

rm index.nginx-debian.html

# Configure Nginx
echo "Configuring Nginx..."
cat <<EOF > /etc/nginx/sites-available/$DOMAIN
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    root /var/www/html;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;

    # FastCGI cache
    fastcgi_cache_path /etc/nginx/cache levels=1:2 keys_zone=wordpress:100m inactive=60m;
    fastcgi_cache_key "\$scheme\$request_method\$host\$request_uri";
    fastcgi_cache_use_stale error timeout invalid_header http_500;

    location ~ \.php\$ {
        fastcgi_cache wordpress;
        fastcgi_cache_valid 200 60m;
    }
}
EOF
ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
rm /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx
check_success "Nginx configuration"

# Install SSL
echo "Installing SSL with Let's Encrypt..."
apt install certbot python3-certbot-nginx -y
certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos --email $EMAIL --redirect
check_success "SSL installation"

# Install Redis for caching
echo "Installing Redis..."
apt install redis-server php-redis -y
systemctl enable redis-server
check_success "Redis installation"

# Additional security
find /var/www/html/ -type d -exec chmod 750 {} \;
find /var/www/html/ -type f -exec chmod 640 {} \;
echo "define('XMLRPC_REQUEST', false);" >> /var/www/html/wp-config.php

# Auto-updates
apt install unattended-upgrades -y

echo "Setup complete! Visit https://$DOMAIN to finish WordPress installation."
echo "Login as $NEWUSER for future access. Install plugins like Redis Object Cache for further optimization."
