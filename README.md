# Automated Deployment Script

this is a bash script for automated docker app deployment with nginx config.

## Features

Automated Docker and Nginx installation
Git repository cloning with PAT auth
safe to re-run
Good error handling and logging
Support for both Dockerfile and docker-compose.yml
Nginx reverse proxy auto-configuration
Health checks and validation
Cleanup mode for resource removal
POSIX-compliant

## Prerequisites

### Local Machine
- Bash 4.0 or higher
- Git installed
- SSH client
- rsync utility


## setup instructions


### 1. configure ssh key

```bash
ssh-keygen -t rsa -b 4096 -C "your_email@example.com"

ssh-copy-id -i ~/.ssh/id_rsa.pub root@SERVERIP

```

### 2. clone the script

```bash
git clone https://github.com/pheonix0x01/deployment-automator.git
cd deployment-automator

chmod +x deploy.sh
```

then run

```bash
./deploy.sh
```
and fill in the deatils

### Cleanup Mode

you can run in cleanup mode to remove all deployed resources:

```bash
./deploy.sh --cleanup
```


## Logging

all operations are logged to timestamped files inside:
```
deploy_YYYYMMDD_HHMMSS.log
```

arigato gozaimasssu

