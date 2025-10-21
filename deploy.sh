#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/deploy_$(date +%Y%m%d_%H%M%S).log"
CLEANUP_MODE=false
PROJECT_DIR=""
CONTAINER_NAME="app_container"
COMPOSE_PROJECT_NAME="deployed_app"

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() {
    echo "[INFO] $*" | tee -a "${LOG_FILE}"
}

log_success() {
    echo "[SUCCESS] $*" | tee -a "${LOG_FILE}"
}

log_warning() {
    echo "[WARNING] $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo "[ERROR] $*" | tee -a "${LOG_FILE}"
}

cleanup_on_error() {
    local exit_code=$?
    log_error "Script failed with exit code ${exit_code}"
    log_error "Check log file: ${LOG_FILE}"
    exit "${exit_code}"
}

trap cleanup_on_error ERR
trap 'log_error "Script interrupted by user"; exit 130' INT TERM

validate_url() {
    local url="$1"
    if [[ ! "$url" =~ ^https?:// ]]; then
        log_error "Invalid URL format: $url"
        return 1
    fi
    return 0
}

validate_ip() {
    local ip="$1"
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "Invalid IP address format: $ip"
        return 1
    fi
    return 0
}

validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "Invalid port number: $port (must be 1-65535)"
        return 1
    fi
    return 0
}

validate_file_exists() {
    local file="$1"
    if [ ! -f "$file" ]; then
        log_error "File not found: $file"
        return 1
    fi
    return 0
}

collect_parameters() {
    log_info "=== Step 1: Collecting Parameters ==="
    
    read -p "enter git repo url chief: " GIT_REPO_URL
    validate_url "$GIT_REPO_URL" || exit 1
    
    read -sp "im going to need a personal access token as well: " GIT_PAT
    echo
    if [ -z "$GIT_PAT" ]; then
        log_error "PAT cannot be empty"
        exit 1
    fi
    
    read -p "enter your branch name (will default to main if empty): " GIT_BRANCH
    GIT_BRANCH="${GIT_BRANCH:-main}"
    
    read -p "enter your ssh username: " SSH_USER
    if [ -z "$SSH_USER" ]; then
        log_error "SSH username cannot be empty"
        exit 1
    fi
    
    read -p "enter your server ip: " SERVER_IP
    validate_ip "$SERVER_IP" || exit 1
    
    read -p "enter the path to your ssh key (like ~/.ssh/id_rsa): " SSH_KEY_PATH
    SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
    validate_file_exists "$SSH_KEY_PATH" || exit 1
    
    read -p "enter your app port: " APP_PORT
    validate_port "$APP_PORT" || exit 1
    
    log_success "looks like all parameters are gucci"
}

clone_repository() {
    log_info "cloning repo..."
    
    REPO_NAME=$(basename "$GIT_REPO_URL" .git)
    PROJECT_DIR="${SCRIPT_DIR}/${REPO_NAME}"
    
    AUTH_URL=$(echo "$GIT_REPO_URL" | sed "s|https://|https://${GIT_PAT}@|")
    
    if [ -d "$PROJECT_DIR" ]; then
        log_info "repo exists. pulling latest diffs..."
        cd "$PROJECT_DIR"
        git fetch origin || { log_error "failed to fetch from origin"; exit 2; }
        git checkout "$GIT_BRANCH" || { log_error "failed to checkout branch $GIT_BRANCH"; exit 2; }
        git pull origin "$GIT_BRANCH" || { log_error "failed to pull latest diffs"; exit 2; }
        log_success "repo updated successfully"
    else
        log_info "cloning repo..."
        git clone -b "$GIT_BRANCH" "$AUTH_URL" "$PROJECT_DIR" || { log_error "failed to clone repo"; exit 2; }
        log_success "repo cloned successfully"
    fi
}

verify_project_structure() {
    log_info "checking for docker in repo..."
    
    cd "$PROJECT_DIR" || { log_error "failed to cd into project directory"; exit 3; }
    
    if [ -f "docker-compose.yml" ]; then
        log_success "found docker-compose.yml"
        DEPLOYMENT_TYPE="compose"
    elif [ -f "Dockerfile" ]; then
        log_success "found dockerfile"
        DEPLOYMENT_TYPE="dockerfile"
    else
        log_error "neither dockerfile nor docker-compose.yml found in repo"
        exit 3
    fi

    log_success "project structure verified"
}

test_ssh_connection() {
    log_info "testing ssh connection..."
    if ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" "echo 'SSH connection successful'" &>/dev/null; then
        log_success "ssh connection established successfully"
    else
        log_error "failed to establish ssh connection"
        exit 4
    fi
}

prepare_remote_environment() {
    log_info "preparing remote environment..."
    
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" bash <<'ENDSSH'
        set -e
        
        echo "[INFO] updating packages..."
        sudo apt-get update -y

        echo "[INFO] installing deps..."
        sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release
        
        if ! command -v docker &> /dev/null; then
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt-get update -y
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io
        else
            echo "[INFO] docker already installed"
        fi
        
        if ! command -v docker-compose &> /dev/null; then
            sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
        else
            echo "[INFO] docker-compose already installed"
        fi
        
        if ! command -v nginx &> /dev/null; then
            echo "[INFO] installing Nginx..."
            sudo apt-get install -y nginx
        else
            echo "[INFO] nginx already installed"
        fi
        
        sudo usermod -aG docker $USER || true
        
        echo "[INFO] enabling and starting docker and ngnix services..."
        sudo systemctl enable docker
        sudo systemctl start docker
        sudo systemctl enable nginx
        sudo systemctl start nginx
        
        echo "[INFO] checking installations..."
        docker --version
        docker-compose --version
        nginx -v
        
        echo "[SUCCESS] remote environment up and activeee"
ENDSSH
    
    log_success "remote environment up and activeee"
}

deploy_application() {
    log_info "deploying app..."
    
    log_info "moving project files to remote server..."
    REMOTE_DIR="/home/${SSH_USER}/deployment/${REPO_NAME}"
    
    ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" "mkdir -p ${REMOTE_DIR}"
    
    rsync -avz -e "ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no" \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='*.log' \
        "${PROJECT_DIR}/" "${SSH_USER}@${SERVER_IP}:${REMOTE_DIR}/"
    
    log_success "files moved successfully"
    
    log_info "building and running docker containers..."
    
    if [ "$DEPLOYMENT_TYPE" = "compose" ]; then
        ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" bash <<ENDSSH
            set -e
            cd ${REMOTE_DIR}
            
            echo "[INFO] stopping existing containers..."
            docker-compose -p ${COMPOSE_PROJECT_NAME} down 2>/dev/null || true
            
            echo "[INFO] checking for containers using port ${APP_PORT}..."
            CONTAINERS_ON_PORT=\$(docker ps -a --format '{{.ID}} {{.Ports}}' | grep ":${APP_PORT}->" | awk '{print \$1}')
            if [ -n "\$CONTAINERS_ON_PORT" ]; then
                echo "[INFO] Found containers on port ${APP_PORT}, stopping them..."
                for container in \$CONTAINERS_ON_PORT; do
                    docker stop \$container 2>/dev/null || true
                    docker rm \$container 2>/dev/null || true
                done
                echo "[SUCCESS] Cleaned up port ${APP_PORT}"
            else
                echo "[INFO] No containers found on port ${APP_PORT}"
            fi
            
            echo "[INFO] building and starting containers..."
            docker-compose -p ${COMPOSE_PROJECT_NAME} up -d --build
            sleep 12
            docker-compose -p ${COMPOSE_PROJECT_NAME} ps
            
            echo "[SUCCESS] app deployed successfully"
ENDSSH
    else
        ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" bash <<ENDSSH
            set -e
            cd ${REMOTE_DIR}

            echo "[INFO] cleaning up existing containers..."
            
            docker stop ${CONTAINER_NAME} 2>/dev/null || true
            docker rm ${CONTAINER_NAME} 2>/dev/null || true
            
            echo "[INFO] checking for containers using port ${APP_PORT}..."
            CONTAINERS_ON_PORT=\$(docker ps -a --format '{{.ID}} {{.Ports}}' | grep ":${APP_PORT}->" | awk '{print \$1}')
            echo "[DEBUG] Found containers: \$CONTAINERS_ON_PORT"
            
            if [ -n "\$CONTAINERS_ON_PORT" ]; then
                echo "[INFO] Found containers using port ${APP_PORT}:"
                echo "\$CONTAINERS_ON_PORT"
                for container in \$CONTAINERS_ON_PORT; do
                    echo "[INFO] Stopping container \$container..."
                    docker stop \$container 2>/dev/null || true
                    docker rm \$container 2>/dev/null || true
                done
                echo "[SUCCESS] Cleaned up port ${APP_PORT}"
            else
                echo "[INFO] No containers found on port ${APP_PORT}"
            fi

            echo "[INFO] Checking if port ${APP_PORT} is free on host..."
            if sudo lsof -i :${APP_PORT} &>/dev/null; then
                echo "[WARNING] Port ${APP_PORT} is in use by a process on host"
                sudo lsof -i :${APP_PORT}
            fi
            
            echo "[INFO] building image..."
            docker build -t ${REPO_NAME}:latest .
            
            echo "[INFO] starting container..."
            docker run -d --name ${CONTAINER_NAME} -p ${APP_PORT}:${APP_PORT} ${REPO_NAME}:latest
            
            sleep 12           
            docker ps | grep ${CONTAINER_NAME}

            echo "[SUCCESS] app deployed successfully"
ENDSSH
    fi
    
    log_success "app deployed and running"
}

configure_nginx() {
    log_info "configuring nginx reverse proxy..."
    
    ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" bash <<ENDSSH
        set -e
        NGINX_CONF="/etc/nginx/sites-available/${REPO_NAME}"
        echo "[INFO] Creating Nginx configuration..."
        sudo tee \$NGINX_CONF > /dev/null <<'EOF'
server {
    listen 80;
    server_name _;
    
    location / {
        proxy_pass http://localhost:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF
        
        sudo rm -f /etc/nginx/sites-enabled/default
        sudo rm -f /etc/nginx/sites-enabled/${REPO_NAME}
        sudo ln -sf \$NGINX_CONF /etc/nginx/sites-enabled/${REPO_NAME}
        echo "[INFO] testing nginx config..."
        sudo nginx -t
        echo "[INFO] reloading nginx..."
        sudo systemctl reload nginx

        echo "[SUCCESS] nginx config successful"
ENDSSH
    
    log_success "nginx reverse proxy configured"
}

validate_deployment() {
    log_info "validating deployment..."
    log_info "checking docker service..."
    ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" "sudo systemctl is-active docker" || {
        log_error "docker service isnt running"
        exit 8
    }
    log_success "docker service is running"

    log_info "checking container status..."
    if [ "$DEPLOYMENT_TYPE" = "compose" ]; then
        ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" "docker-compose -f /home/${SSH_USER}/deployment/${REPO_NAME}/docker-compose.yml -p ${COMPOSE_PROJECT_NAME} ps | grep -i 'up'" || {
            log_error "containers are not running properly"
            exit 8
        }
    else
        ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" "docker ps | grep ${CONTAINER_NAME}" || {
            log_error "container isnt running"
            exit 8
        }
    fi
    log_success "container is running"
    
    log_info "checking nginx service..."
    ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" "sudo systemctl is-active nginx" || {
        log_error "nginx service is not running"
        exit 8
    }
    log_success "nginx service is running"
    
    log_info "now testing app endpoint..."
    sleep 7
    if ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" "curl -f -s -o /dev/null -w '%{http_code}' http://localhost:${APP_PORT}" | grep -q "200\|301\|302"; then
        log_success "app is responding on port ${APP_PORT}"
    else
        log_warning "app dey gbaaa"
    fi
    
    log_info "testing nginx reverse proxy..."
    if ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" "curl -f -s -o /dev/null -w '%{http_code}' http://localhost" | grep -q "200\|301\|302"; then
        log_success "nginx reverse proxy is working. hurray"
    else
        log_warning "nginx proxy dey gbaaa"
    fi
    
    log_success "deployment checks completed"
    log_info "app is accessible at: http://${SERVER_IP}...hopefully"
}

perform_cleanup() {
    log_info "performin cleanup..."
    
    ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${SERVER_IP}" bash <<ENDSSH
        set -e
        
        echo "[INFO] stopping and removing containers..."
        docker-compose -f /home/${SSH_USER}/deployment/${REPO_NAME}/docker-compose.yml -p ${COMPOSE_PROJECT_NAME} down 2>/dev/null || true
        docker stop ${CONTAINER_NAME} 2>/dev/null || true
        docker rm ${CONTAINER_NAME} 2>/dev/null || true

        echo "[INFO] removing nginx configuration..."
        sudo rm -f /etc/nginx/sites-enabled/${REPO_NAME}
        sudo rm -f /etc/nginx/sites-available/${REPO_NAME}
        sudo systemctl reload nginx

        echo "[INFO] removing project files..."
        rm -rf /home/${SSH_USER}/deployment/${REPO_NAME}
        
        echo "[SUCCESS] cleanup completed. i was never here"
ENDSSH
    
    log_success "cleanup completed. i was never here"
}

main() {
    log_info "automated deployment script activeeee"
    log_info "run with --cleanup flag if you want to clean up after next time"
    log_info "log file here: ${LOG_FILE}"
    echo ""
    
    if [[ "${1:-}" == "--cleanup" ]]; then
        CLEANUP_MODE=true
        log_info "Running in cleanup mode"
        
        read -p "enter ssh username: " SSH_USER
        read -p "enter server ip: " SERVER_IP
        read -p "enter path to ssh key: " SSH_KEY_PATH
        SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
        read -p "enter repo name to clean: " REPO_NAME

        perform_cleanup
        log_success "script completed successfully. (or at least i hope so)"
        exit 0
    fi
    
    collect_parameters
    clone_repository
    verify_project_structure
    test_ssh_connection
    prepare_remote_environment
    deploy_application
    configure_nginx
    validate_deployment
    
    echo ""
    log_success "deployment completed successfully!!!!"
    log_info "application url: http://${SERVER_IP}"
    log_info "log file here: ${LOG_FILE}"
    echo ""
    
    exit 0
}

main "$@"