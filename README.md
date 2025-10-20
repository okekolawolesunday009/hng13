# Deployment Script

This script automates the deployment of a Dockerized application to a remote server, including cloning a Git repository, building and running Docker containers, and configuring Nginx as a reverse proxy.

## Features

- Clones the specified Git repository and checks out a branch (default: `main`)
- Builds and deploys Docker containers using Docker Compose on a remote server
- Installs Docker, Docker Compose, and Nginx if missing on the remote server
- Configures Nginx as a reverse proxy to the application port
- Performs health checks on Docker containers and the deployed application
- Supports cleanup mode to remove deployment artifacts from the remote server
- Logs all output to a timestamped log file

## Prerequisites

- Remote server with SSH access and a user with sudo privileges
- SSH private key for passwordless authentication
- Personal Access Token (PAT) for accessing private Git repositories (if needed)
- The application repository must contain either a `Dockerfile` or `docker-compose.yml`

## Usage

### Deploy application

Run the script and provide the required information when prompted:

```sh
./deploy.sh
