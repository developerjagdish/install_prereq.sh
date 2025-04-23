#!/bin/bash

# Check if domain name or IP and RDS details are provided
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ]; then
  echo "Usage: ./setup_n8n_docker.sh <your_domain_or_ip> <RDS_HOST> <POSTGRES_USER> <POSTGRES_PASSWORD> <POSTGRES_DB>"
  exit 1
fi

DOMAIN_OR_IP=$1
RDS_HOST=$2
POSTGRES_USER=$3
POSTGRES_PASSWORD=$4
POSTGRES_DB=$5

# Clear any potential conflicting environment variables
unset PGUSER
unset PGPASSWORD

# Function to check if a command exists
command_exists() {
  command -v "$1" &> /dev/null
}

# Function to generate a secure random encryption key
generate_encryption_key() {
  openssl rand -base64 32
}

# Update the system
echo "Updating the system..."
sudo yum update -y

# Install PostgreSQL client tools if not already installed
if ! command_exists psql; then
  echo "Installing PostgreSQL client tools..."
  sudo yum install -y postgresql15
else
  echo "PostgreSQL client tools are already installed."
fi

# Install Docker if not already installed
if ! command_exists docker; then
  echo "Installing Docker..."
  sudo yum install -y docker
  sudo systemctl start docker
  sudo systemctl enable docker
  sudo usermod -aG docker $USER
else
  echo "Docker is already installed."
  sudo systemctl start docker
fi

# Install Docker Compose if not already installed
if ! command_exists docker-compose; then
  echo "Installing Docker Compose..."
  sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
else
  echo "Docker Compose is already installed."
fi

# Verify Docker and Docker Compose installation
docker --version
docker-compose --version

# Create a directory for n8n and navigate to it
mkdir -p ~/n8n-docker
cd ~/n8n-docker

# Download the RDS SSL certificate
echo "Downloading RDS SSL certificate..."
wget https://s3.amazonaws.com/rds-downloads/rds-combined-ca-bundle.pem -O rds-ca.pem

# Generate or check for an existing N8N_ENCRYPTION_KEY
if [ ! -f ".env" ]; then
  echo "Generating new encryption key..."
  N8N_ENCRYPTION_KEY=$(generate_encryption_key)
else
  echo "Encryption key already exists, loading from .env..."
  N8N_ENCRYPTION_KEY=$(grep 'N8N_ENCRYPTION_KEY' .env | cut -d '=' -f2)
  if [ -z "$N8N_ENCRYPTION_KEY" ]; then
    echo "No encryption key found in .env, generating a new one..."
    N8N_ENCRYPTION_KEY=$(generate_encryption_key)
  fi
fi

# Create the .env file for sensitive data if it doesn't exist
if [ ! -f ".env" ]; then
  echo "Creating .env file..."
  cat <<EOL > .env
# AWS RDS Configuration
RDS_HOST=$RDS_HOST
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB

# Basic Auth for n8n
N8N_BASIC_AUTH_USER=yourUsername
N8N_BASIC_AUTH_PASSWORD=yourPassword

# Domain and SSL Configuration
DOMAIN_NAME=$DOMAIN_OR_IP
N8N_PATH=/

# Redis Configuration (if applicable)
REDIS_HOST=redis

# Encryption Key for n8n
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY

# Email for SSL certificate
SSL_EMAIL=you@example.com
EOL
else
  echo ".env file already exists."
fi

# Create init-data.sh file for PostgreSQL initialization if it doesn't exist
if [ ! -f "init-data.sh" ]; then
  echo "Creating init-data.sh for PostgreSQL initialization..."
  cat <<EOL > init-data.sh
#!/bin/bash
set -e

RDS_HOST=\$1
POSTGRES_USER=\$2
POSTGRES_PASSWORD=\$3
POSTGRES_DB=\$4

# Set the password for PostgreSQL commands
export PGPASSWORD=\$POSTGRES_PASSWORD

# Check if the database exists; if not, create it
DB_EXISTS=\$(psql -v ON_ERROR_STOP=1 --host="\$RDS_HOST" --username="\$POSTGRES_USER" --dbname="postgres" --tuples-only --command="SELECT 1 FROM pg_database WHERE datname='\$POSTGRES_DB';")

if [[ -z \$DB_EXISTS ]]; then
  echo "Database \$POSTGRES_DB does not exist. Creating database..."
  psql -v ON_ERROR_STOP=1 --host="\$RDS_HOST" --username="\$POSTGRES_USER" --dbname="postgres" --command="CREATE DATABASE \$POSTGRES_DB;"
else
  echo "Database \$POSTGRES_DB already exists."
fi

# Grant privileges to the POSTGRES_USER
psql -v ON_ERROR_STOP=1 --host="\$RDS_HOST" --username="\$POSTGRES_USER" --dbname="\$POSTGRES_DB" <<EOSQL
GRANT ALL PRIVILEGES ON DATABASE \$POSTGRES_DB TO \$POSTGRES_USER;
GRANT CREATE ON SCHEMA public TO \$POSTGRES_USER;
EOSQL

# Unset the password variable after the operations
unset PGPASSWORD
EOL
  chmod +x init-data.sh
else
  echo "init-data.sh already exists."
fi

# Ensure PostgreSQL is reachable and run the initialization script
echo "Checking connectivity to PostgreSQL on RDS..."
until PGPASSWORD=$POSTGRES_PASSWORD psql --host="$RDS_HOST" --username="$POSTGRES_USER" --dbname="postgres" -c '\q'; do
  echo "PostgreSQL is unavailable - sleeping"
  sleep 5
done

echo "PostgreSQL is up - running init-data.sh to initialize the database..."
./init-data.sh "$RDS_HOST" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$POSTGRES_DB"

# Create the Docker Compose file for n8n with Redis and Worker setup if it doesn't exist
if [ ! -f "docker-compose.yml" ]; then
  echo "Creating Docker Compose file..."
  cat <<EOL > docker-compose.yml
version: '3.8'

volumes:
  n8n_storage:
  redis_storage:

services:
  redis:
    image: redis:6-alpine
    restart: always
    volumes:
      - redis_storage:/data
    healthcheck:
      test: ['CMD', 'redis-cli', 'ping']
      interval: 5s
      timeout: 5s
      retries: 10

  n8n:
    image: docker.n8n.io/n8nio/n8n
    restart: always
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=$RDS_HOST
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=$POSTGRES_DB
      - DB_POSTGRESDB_USER=$POSTGRES_USER
      - DB_POSTGRESDB_PASSWORD=$POSTGRES_PASSWORD
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_HEALTH_CHECK_ACTIVE=true
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
      - DB_POSTGRESDB_SSL_CA=/rds-ca.pem
      - DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=false
      - N8N_HOST=$DOMAIN_OR_IP
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://$DOMAIN_OR_IP${N8N_PATH}
      - N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
    ports:
      - 5678:5678
    volumes:
      - n8n_storage:/home/node/.n8n
      - /home/ec2-user/n8n/rds-ca.pem:/rds-ca.pem  # Mount the RDS CA certificate

  n8n-worker:
    image: docker.n8n.io/n8nio/n8n
    restart: always
    command: worker
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=$RDS_HOST
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=$POSTGRES_DB
      - DB_POSTGRESDB_USER=$POSTGRES_USER
      - DB_POSTGRESDB_PASSWORD=$POSTGRES_PASSWORD
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_HEALTH_CHECK_ACTIVE=true
      - N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
    depends_on:
      - n8n
EOL
else
  echo "Docker Compose file already exists."
fi

# Start the n8n service using Docker Compose
echo "Starting n8n service using Docker Compose..."
docker-compose up -d

# Install Nginx if not already installed
if ! command_exists nginx; then
  echo "Installing Nginx..."
  sudo yum install -y nginx
  sudo systemctl start nginx
  sudo systemctl enable nginx
else
  echo "Nginx is already installed."
  sudo systemctl start nginx
fi

# Create an Nginx configuration with SSL placeholder
FINAL_NGINX_CONF="/etc/nginx/conf.d/n8n.conf"
if [ ! -f "$FINAL_NGINX_CONF" ]; then
  echo "Creating Nginx configuration with SSL placeholder..."
  sudo tee $FINAL_NGINX_CONF > /dev/null <<EOL
server {
    server_name $DOMAIN_OR_IP;

    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    listen 80;
    listen [::]:80;

    listen 443 ssl; # Placeholder for SSL
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_OR_IP/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_OR_IP/privkey.pem;
}
EOL
else
  echo "Nginx configuration already exists."
fi

# Test and reload Nginx with the new configuration
sudo nginx -t && sudo systemctl reload nginx

# Install Certbot and obtain SSL certificate
if [ ! -f "/etc/letsencrypt/live/$DOMAIN_OR_IP/fullchain.pem" ]; then
  echo "Installing Certbot and obtaining SSL certificate..."
  sudo yum install -y certbot python3-certbot-nginx
  sudo certbot certonly --nginx -d $DOMAIN_OR_IP
else
  echo "SSL certificate already exists."
fi

# Enable SSL in the Nginx configuration
sudo tee $FINAL_NGINX_CONF > /dev/null <<EOL
server {
    server_name $DOMAIN_OR_IP;

    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_OR_IP/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_OR_IP/privkey.pem;
}

server {
    if (\$host = $DOMAIN_OR_IP) {
        return 301 https://\$host\$request_uri;
    }

    listen 80;
    server_name $DOMAIN_OR_IP;
    return 404;
}
EOL

# Test and reload Nginx with the final configuration
sudo nginx -t && sudo systemctl reload nginx

echo "Setup complete. n8n is now running and accessible at https://$DOMAIN_OR_IP."