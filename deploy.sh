#!/bin/sh

# ===== CONFIGURATION =====
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="deploy_$TIMESTAMP.log"
EXIT_SUCCESS=0
EXIT_INPUT_ERROR=1
EXIT_DEPLOY_ERROR=2

# Redirect all stdout and stderr to log file with tee (log + console)
exec > >(tee -a "$LOG_FILE") 2>&1

# Trap unexpected errors and signals
trap 'echo "[ERROR] An unexpected error occurred. Exiting." | tee -a "$LOG_FILE"; exit $EXIT_DEPLOY_ERROR' 1 2 3 15

# ===== FUNCTION: Log and Echo =====
log() {
    echo "[`date +'%Y-%m-%d %H:%M:%S'`] $*"
}

# ===== CLEANUP MODE =====
if [ "$1" = "--cleanup" ]; then
    printf "Are you sure you want to cleanup the deployment? (y/n): "; read confirm
    if [ "$confirm" != "y" ]; then
        log "Cleanup aborted by user."
        exit $EXIT_SUCCESS
    fi

    printf "SSH Username: "; read ssh_user
    printf "Server IP address: "; read server_ip
    printf "SSH key path: "; read ssh_key_path

    if [ -z "$ssh_user" ] || [ -z "$server_ip" ] || [ -z "$ssh_key_path" ] || [ ! -f "$ssh_key_path" ]; then
        log "[INPUT ERROR] Invalid cleanup parameters."
        exit $EXIT_INPUT_ERROR
    fi

    log "Initiating cleanup on remote server..."
    ssh -i "$ssh_key_path" "$ssh_user@$server_ip" << 'EOF'
        set -e
        REPO_DIR=$(ls -d */ | head -n 1 || echo "")
        if [ -n "$REPO_DIR" ]; then
            sudo docker-compose -f ~/"$REPO_DIR"/docker-compose.yml down || true
            sudo rm -rf ~/"$REPO_DIR"
        fi
        sudo docker system prune -af
        sudo rm -f /etc/nginx/sites-enabled/myapp || true
        sudo rm -f /etc/nginx/sites-available/myapp || true
        sudo systemctl reload nginx || true
        echo "Cleanup completed."
EOF
    exit $EXIT_SUCCESS
fi

# ===== INPUTS =====
printf "Git Repository URL: "; read repo_url
printf "Personal Access Token: "; stty -echo; read access_token; stty echo; echo
printf "Branch name (default: main): "; read branch_name
printf "SSH Username: "; read ssh_user
printf "Server IP address: "; read server_ip
printf "SSH key path: "; read ssh_key_path
printf "Application port: "; read app_port

branch_name="${branch_name:-main}"

# ===== VALIDATE INPUTS =====
if [ -z "$repo_url" ]; then
    log "[INPUT ERROR] Git Repository URL is required."
    exit $EXIT_INPUT_ERROR
fi
if [ -z "$access_token" ]; then
    log "[INPUT ERROR] Personal Access Token is required."
    exit $EXIT_INPUT_ERROR
fi
if [ -z "$ssh_user" ]; then
    log "[INPUT ERROR] SSH Username is required."
    exit $EXIT_INPUT_ERROR
fi
if [ -z "$server_ip" ]; then
    log "[INPUT ERROR] Server IP address is required."
    exit $EXIT_INPUT_ERROR
fi
if [ -z "$ssh_key_path" ] || [ ! -f "$ssh_key_path" ]; then
    log "[INPUT ERROR] Valid SSH key path is required."
    exit $EXIT_INPUT_ERROR
fi
if ! echo "$app_port" | grep -qE '^[0-9]{2,5}$'; then
    log "[INPUT ERROR] Application port must be a number between 2 and 5 digits."
    exit $EXIT_INPUT_ERROR
fi

log "Collected user input."
echo "Git Repository URL: $repo_url"
echo "Branch name: $branch_name"
echo "SSH Username: $ssh_user"
echo "Server IP address: $server_ip"
echo "SSH key path: $ssh_key_path"
echo "Application port: $app_port"

printf "Are these details correct? (y/n): "; read confirm
if [ "$confirm" != "y" ]; then
    log "[INPUT ERROR] User aborted due to incorrect details."
    exit $EXIT_INPUT_ERROR
fi

# ===== CLONE REPO =====
repo_dir=$(basename "$repo_url" .git)
if [ -d "$repo_dir" ]; then
    log "Repository directory already exists. Pulling latest changes..."
    cd "$repo_dir" || { log "[ERROR] Cannot cd into $repo_dir."; exit $EXIT_DEPLOY_ERROR; }
    git pull || { log "[ERROR] Git pull failed."; exit $EXIT_DEPLOY_ERROR; }
else
    # Use GIT_ASKPASS to avoid exposing token in logs or command history
    GIT_ASKPASS_SCRIPT=$(mktemp)
    echo "echo '$access_token'" > "$GIT_ASKPASS_SCRIPT"
    chmod +x "$GIT_ASKPASS_SCRIPT"
    GIT_ASKPASS="$GIT_ASKPASS_SCRIPT" git clone "$repo_url" "$repo_dir" || { log "[ERROR] Git clone failed."; rm "$GIT_ASKPASS_SCRIPT"; exit $EXIT_DEPLOY_ERROR; }
    rm "$GIT_ASKPASS_SCRIPT"
    cd "$repo_dir" || { log "[ERROR] Cannot cd into $repo_dir after clone."; exit $EXIT_DEPLOY_ERROR; }
fi

git checkout "$branch_name" || { log "[ERROR] Branch checkout failed."; exit $EXIT_DEPLOY_ERROR; }

# ===== CHECK REQUIRED FILES =====
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
    log "Found Docker configuration files."
else
    log "[ERROR] Neither Dockerfile nor docker-compose.yml found in repo."
    exit $EXIT_DEPLOY_ERROR
fi

# ===== VERIFY SERVER REACHABILITY =====
ping -c 1 "$server_ip" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    log "Host server $server_ip is reachable."
else
    log "[ERROR] Host $server_ip is unreachable."
    exit $EXIT_DEPLOY_ERROR
fi

# ===== PREPARE REMOTE SERVER =====
log "Preparing remote server..."

ssh -i "$ssh_key_path" "$ssh_user@$server_ip" sh << EOF
    set -e
    sudo apt-get update -y
    sudo apt-get install -y docker.io docker-compose nginx
    sudo usermod -aG docker "$ssh_user" || true

    sudo systemctl enable docker
    sudo systemctl start docker

    docker --version
    docker-compose --version
    nginx -v
EOF

# ===== TRANSFER PROJECT FILES =====
log "Cleaning up existing project directory on remote server..."
ssh -i "$ssh_key_path" "$ssh_user@$server_ip" "rm -rf ~/$repo_dir"

log "Transferring project files..."
scp -i "$ssh_key_path" -r . "$ssh_user@$server_ip:~/"

# ===== DEPLOY ON REMOTE SERVER =====
log "Stopping any existing containers..."
ssh -i "$ssh_key_path" "$ssh_user@$server_ip" "cd ~/$repo_dir && sudo docker-compose down || true"

log "Starting containers with docker-compose..."
ssh -i "$ssh_key_path" "$ssh_user@$server_ip" sh << EOF
    cd ~/$repo_dir || exit
    sudo docker-compose up -d --build
EOF

# ===== VERIFY CONTAINER HEALTH =====
log "Checking Docker container health..."

container_id=$(ssh -i "$ssh_key_path" "$ssh_user@$server_ip" "sudo docker ps -q --filter ancestor=$(basename "$repo_url" .git)")
if [ -n "$container_id" ]; then
    retries=0
    until ssh -i "$ssh_key_path" "$ssh_user@$server_ip" "sudo docker inspect --format='{{.State.Health.Status}}' $container_id" 2>/dev/null | grep -q "healthy"; do
        if [ $retries -ge 10 ]; then
            log "[ERROR] Container did not become healthy in time."
            exit $EXIT_DEPLOY_ERROR
        fi
        log "Waiting for container to become healthy... retry $retries"
        sleep 3
        retries=$((retries+1))
    done
    log "Container is healthy."
else
    log "[WARNING] No container found for health check. Skipping."
fi

# ===== VERIFY APP STATUS =====
log "Checking application availability on port $app_port..."
ssh -i "$ssh_key_path" "$ssh_user@$server_ip" "curl -f http://localhost:$app_port" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    log "Application is running on port $app_port."
else
    log "[ERROR] Application is not reachable on port $app_port."
    exit $EXIT_DEPLOY_ERROR
fi

# ===== CONFIGURE NGINX =====
log "Configuring Nginx as reverse proxy..."

ssh -i "$ssh_key_path" "$ssh_user@$server_ip" sh << EOF
    sudo rm -f /etc/nginx/sites-enabled/myapp /etc/nginx/sites-available/myapp || true
    sudo sh -c 'cat > /etc/nginx/sites-available/myapp' << EOL
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://localhost:$app_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL
    sudo ln -s /etc/nginx/sites-available/myapp /etc/nginx/sites-enabled/ || true
    sudo nginx -t && sudo systemctl reload nginx
EOF

# ===== VERIFY NGINX PROXY =====
log "Verifying Nginx proxy configuration..."

ssh -i "$ssh_key_path" "$ssh_user@$server_ip" "sudo nginx -t"
if [ $? -ne 0 ]; then
    log "[ERROR] Nginx configuration test failed."
    exit $EXIT_DEPLOY_ERROR
fi

log "Checking external accessibility through Nginx..."
curl -f "http://$server_ip" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    log "Application is accessible externally via Nginx."
else
    log "[ERROR] Application is not accessible externally via Nginx."
    exit $EXIT_DEPLOY_ERROR
fi

log "Deployment completed successfully."

# ===== FINAL VERIFICATION =====

# Docker service is running.
sudo systemctl status docker
# The target container is active and healthy.
sudo docker ps

# Nginx is proxying correctly.
sudo nginx -t

curl -f http://localhost:$app_port >/dev/null 2>&1

exit $EXIT_SUCCESS
