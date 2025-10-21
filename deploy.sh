#!/bin/bash
 set -e #exit immediately if any commmand fails

 stage1_flag=".stage1_done"
 stage2_flag=".stage2_done"
 stage3_flag=".stage3_done"
 #stage1_flag=".stage4_done"


 echo --- Parameters for users input ---
read -p "Enter Git repository URL:" repo_url
read -p "Enter Personal Access Token (PAT): " pat
read -p "Enter Branch Name [main]: " branch
branch=${branch:-main}
read -p "Enter Remote Server SSH username: " ssh_user
read -p "Enter Remote Server IP address: " server_ip
read -p "Enter Remote Server SSH key path: " ssh_key

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
if ssh -i "$ssg_key" -o BatchMode=yes -o ConnectTimeout=01 "$ssh_user@$ssh_serverip"
  echo "SSH connection verified."
else 
  echo "Error: SSH connection failed."
  echo "check your username, ip, or SSH key permission"
  exit 1
fi

echo "checking system info on remote server..."
ssh -i "$ssh_key" "$ssh_user@$server_ip" "uname -a && whoami"

echo "Remote SSH verification complete. Ready to run remote setup command." 
if [ ! -f "$stage3_flag" ]; then
    echo "--- Stage 3: SSH Connection ---"
    # (SSH logic here)
    touch "$stage3_flag"
    echo "Stage 3 complete."
else
    echo "Skipping Stage 3 — already done."
fi 
