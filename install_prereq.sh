#!/bin/bash

# Update the system
sudo yum update -y

# Install Nginx
sudo yum install -y nginx

# Start and enable Nginx service
sudo systemctl start nginx
sudo systemctl enable nginx

# Install EPEL repository (for Certbot and other packages)
sudo yum install -y epel-release

# Install Certbot for SSL certificates
sudo yum install -y certbot python3-certbot-nginx

# Install Crontab (should already be installed, but just in case)
sudo yum install -y cronie
sudo systemctl start crond
sudo systemctl enable crond

# Install Python and Pip
sudo yum install -y python3 python3-pip

# Install Git
sudo yum install -y git

# Install Docker
sudo yum install -y docker

# Start and enable Docker service
sudo systemctl start docker
sudo systemctl enable docker

# Add the current user to the Docker group
sudo usermod -aG docker $USER

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

echo "Installing PostgreSQL client tools..."
sudo yum install -y postgresql15

# Install Node.js (required for running N8N)
curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash -
sudo yum install -y nodejs

# Install PM2 to manage N8N processes
sudo npm install -g pm2

# Install N8N
#sudo npm install -g n8n

echo "Installation complete. Please run the setup script to configure Nginx and N8N."
