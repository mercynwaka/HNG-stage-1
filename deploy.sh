#!/bin/bash
 set -e #exit immediately if any commmand fails

 stage1_flag=".stage1_done"
 stage2_flag=".stage2_done"
 stage3_flag=".stage3_done"
 


 echo --- Parameters for users input ---
read -p "Enter Git repository URL:" repo_url
read -p "Enter Personal Access Token (PAT): " pat
read -p "Enter Branch Name [main]: " branch
branch=${branch:-main}
read -p "Enter Remote Server SSH username: " ssh_user
read -p "Enter SSH port [22]: " ssh_port
ssh_port=${ssh_port:-22}
read -p "Enter Remote Server IP address: " server_ip
read -p "Enter Remote Server SSH key path: " ssh_key
ssh_key="${ssh_key/#\~/$HOME}"

echo ""
echo "All inputs collected successfully"

echo "--- Clone or Update Repository ---"
repo_name=$(basename "$repo_url" .git)
current_dir=$(basename "$PWD")

if [ "$current_dir" = "$repo_name" ]; then
  echo "Already inside '$repo_name' directory."
  if [ -d .git ]; then
    echo "Repository already initialized. Pulling latest changes..."
    git fetch origin
    git checkout "$branch" || git checkout -b "$branch"
    git pull origin "$branch"
  else
    echo "Initializing repository in current directory..."
    git init
    git remote add origin https://$pat@${repo_url#https://}
    git fetch origin "$branch"
    git checkout -b "$branch" FETCH_HEAD
  fi

else
  if [ -d "$repo_name" ]; then
    echo "Repo '$repo_name' exists. Pulling latest changes..."
    cd "$repo_name"
    git fetch origin
    git checkout "$branch" || git checkout -b "$branch"
    git pull origin "$branch"
  else
    echo "Cloning repository '$repo_name' ..."
    git clone https://$pat@${repo_url#https://} -b "$branch" "$repo_name"
    cd "$repo_name"
  fi
fi  

echo "Repository ready and on branch '$branch'."


if [ ! -f "$stage1_flag" ]; then
    # Mark Stage 1 as completed
  cd ..
  touch "$stage1_flag"
  echo "Stage 1 complete."
else
   echo "Skipping Stage 1 — repository already cloned."
fi



echo --- verify project directory for docker files ---
if [ "$(basename "$PWD")" != "$repo_name" ]; then
  if  [  ! -d "$repo_name" ]; then 
    echo "Error: repository directory '$repo_name' not found."
    exit 1
  fi

  cd "$repo_name" || { echo "Failed to enter directory '$repo_name'."; exit 1; }
else
  echo "Already inside '$repo_name' directory."
fi

if [ -f "Dockerfile" ]; then
  echo "Dockerfile found in directory."
  DEPLOY_MODE="dockerfile"
elif [ -f "docker-compose.yaml" ] || [ -f "docker-compose.yml" ]; then
  echo "docker-compose file found in directory."
  DEPLOY_MODE="docker-compose"

else
  echo "Error: No Dockerfile or docker-compose file found."
  exit 1
fi
    stage2_flag=false
if [ ! -f "$stage2_flag" ]; then
    echo "--- Stage 2: Validate Project Files ---"
    # (Stage 2 logic here)
    stage2_flag=true
    echo "Stage 2 complete."
else
    echo "Skipping Stage 2 — already done."
fi



echo --- connect [ssh] into remote server ---
# ping
echo "pinging remote server $server_ip..."
if ping -c 2 "$server_ip" > /dev/null 2>&1; then
  echo "ping successful, server reachable"
else
  echo " Warning: ping failed. Continuing to test for SSH..."
fi

#Test SSH connection
echo "Testing SSH connection..."
if ssh -i "$ssh_key" -p 22 -o BatchMode=yes -o ConnectTimeout=1 "$ssh_user@$server_ip" "exit" >/dev/null 2>&1; then
  echo "SSH connection verified."
else 
  echo "Error: SSH connection failed."
  echo "check your username, ip, or SSH key permission"
  exit 1
fi

echo "checking system info on remote server..."
ssh -i "$ssh_key" -p 22 "$ssh_user@$server_ip" "uname -a && whoami"

echo "Remote SSH verification complete. Ready to connect interactively." 
   stage3_flag=false
if [ "$stage3_flag" = false ]; then
    echo "--- Stage 3: SSH Connection ---"
   
    # Connect to remote server interactively
    echo "Connecting to remote server..."
    ssh -i "$ssh_key" -p 22 "$ssh_user@$server_ip"

    stage3_flag=true
    echo "Stage 3 complete."
else
    echo "Skipping Stage 3 — already done."
fi

  echo "--- Prepare the Remote Environment ---"

ssh -i "$ssh_key" -p "$ssh_port" "$ssh_user@$server_ip" << 'EOF'
echo "Updating system packages..."
  sudo apt update 

  echo "Installing Docker if missing..."
if ! command -v docker &> /dev/null; then
    sudo apt install -y docker.io
fi

  echo "Installing Docker Compose if missing..."
if ! command -v docker-compose &> /dev/null; then
    sudo apt install -y docker-compose
fi

  echo "Installing Nginx if missing..."
if ! command -v nginx &> /dev/null; then
    sudo apt install -y nginx
fi

  echo "Adding user to Docker group if needed..."
if ! groups $USER | grep -q '\bdocker\b'; then
    sudo usermod -aG docker $USER
    echo "You may need to log out and back in for group changes to take effect."
fi

  echo "Enabling and starting Docker and Nginx..."
  sudo systemctl enable docker
  sudo systemctl start docker
  sudo systemctl enable nginx
  sudo systemctl start nginx

  echo "Confirming installation versions..."
  docker --version
  docker-compose --version
  nginx -v
EOF

echo "Stage  complete — remote environment is ready."


echo "--- Stage: Deploy Dockerized Application ---"

rsync -avz --delete -e "ssh -i $ssh_key -p $ssh_port" . "$ssh_user@$server_ip:/home/$ssh_user/HNG-stage-1/" #this transfers project file to remote


# Run deployment commands on remote server
ssh -i "$ssh_key" -p "$ssh_port" "$ssh_user@$server_ip" << 'EOF'
  cd ~/HNG-stage-1

echo "Ensuring Docker network exists..."
  docker network inspect hng-net >/dev/null 2>&1 || docker network create hng-net

echo "Building Docker image..."
  docker build -t hng-app .

echo "Running Docker container..."
  docker run -d --name hng-app-container -p 80:80 hng-app

echo "Checking container status..."
  docker ps

echo "Showing container logs..."
  docker logs hng-app-container --tail 20

echo "Validating app accessibility..."
  curl -I localhost
EOF

echo "Stage: complete — app deployed and running."


echo "--- Stage: Configure Nginx as Reverse Proxy ---"

ssh -i "$ssh_key" -p "$ssh_port" "$ssh_user@$server_ip" << 'EOF'

    echo "Removing existing Nginx config if present..."
    sudo rm -f /etc/nginx/sites-enabled/hng-app.conf
    sudo rm -f /etc/nginx/sites-available/hng-app.conf


    echo "Creating new Nginx reverse proxy config..."
  sudo tee /etc/nginx/sites-available/hng-app.conf > /dev/null << 'NGINX'
server {
    listen 80;
    server_name localhost;

    location / {
        proxy_pass http://127.0.0.1:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

   
}
NGINX

  echo "Enabling Nginx config..."
  sudo ln -sf /etc/nginx/sites-available/hng-app.conf /etc/nginx/sites-enabled/hng-app.conf

  echo "Testing Nginx configuration..."
  sudo nginx -t

  echo "Reloading Nginx..."
  sudo systemctl reload nginx

  echo "Nginx reverse proxy configured."
EOF

echo "Stage: complete — Nginx is forwarding traffic to Docker container."

echo "--- Stage: Validate Deployment ---"

ssh -i "$ssh_key" -p "$ssh_port" "$ssh_user@$server_ip" << 'EOF'
  echo "Checking Docker service status..."
  sudo systemctl is-active docker && echo " Docker is running." || echo " Docker is not running."

  echo "Checking container health..."
  docker ps --filter "name=hng-app-container" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

  echo "Testing Nginx proxy locally..."
  curl -I http://localhost

  echo "Testing endpoint with wget..."
  wget --spider -S http://localhost 2>&1 | grep "HTTP/"
EOF

echo "Testing endpoint remotely from source machine..."
curl -I http://$server_ip

echo "Stage complete — deployment validated."

echo " --- logging setup --- "
# Timestamped log file
Log_file="deploy_$(date +%Y%m%d).log"

# Log function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$log_file"
}

# Error handler
handle_error() {
  log " ERROR during $current_stage (exit code $?)"
  exit $1
}

# Trap unexpected errors
trap 'handle_error $?' ERR
set -e  # Exit on any command failure



if [[ "$1" == "--cleanup" ]]; then
  log "--- Cleanup Mode Activated ---"
  ssh -i "$ssh_key" -p "$ssh_port" "$ssh_user@$server_ip" << 'EOF'
    docker rm -f hng-app-container 2>/dev/null || echo "No container to remove."
    docker rmi hng-app 2>/dev/null || echo "No image to remove."
    sudo rm -f /etc/nginx/sites-enabled/hng-app.conf
    sudo rm -f /etc/nginx/sites-available/hng-app.conf
    sudo systemctl reload nginx
    rm -rf ~/HNG-stage-1
    echo "Cleanup complete."
EOF
  log "Cleanup complete. Exiting."
  exit 1
fi
