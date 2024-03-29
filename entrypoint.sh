#!/bin/sh
set -eu

# check if required parameters provided
if [ -z "$SSH_USER" ]; then
    echo "Input ssh_host is required!"
    exit 1
fi

if [ -z "$SSH_HOST" ]; then
    echo "Input ssh_user is required!"
    exit 1
fi

if [ -z "$SSH_PORT" ]; then
  SSH_PORT=22
fi

if [ -n "$SSH_JUMP_HOST" ]; then
    if [ -z "$SSH_JUMP_PUBLIC_KEY" ]; then
        echo "Input ssh_jump_public_key is required!"
        exit 1
    fi
fi

if [ -z "$SSH_PRIVATE_KEY" ]; then
    echo "Input ssh_private_key is required!"
    exit 1
fi

if [ -z "$DOCKER_COMPOSE_FILENAME" ]; then
  DOCKER_COMPOSE_FILENAME=docker-compose.yml
fi

if [ -z "$DOCKER_ARGS" ]; then
  DOCKER_ARGS="-d --remove-orphans --build"
fi

if [ -z "$DOCKER_PRE_ARGS" ]; then
  DOCKER_PRE_ARGS=""
fi

if [ -z "$DOCKER_USE_STACK" ]; then
  DOCKER_USE_STACK=false
else
  if [ -z "$DOCKER_COMPOSE_PREFIX" ]; then
    echo "Input docker_compose_prefix is required!"
    exit 1
  fi

  if [ -z "$DOCKER_ARGS" ]; then
    DOCKER_ARGS=""
  fi

  if [ -z "$DOCKER_PRE_ARGS" ]; then
    DOCKER_PRE_ARGS=""
  fi
fi

if [ -z "$DOCKER_ENV" ]; then
  DOCKER_ENV=''
fi

if [ -z "$WORKSPACE" ]; then
  WORKSPACE=workspace
fi

if [ -z "$WORKSPACE_KEEP" ]; then
  WORKSPACE_KEEP=false
fi

log() {
  echo ">> [local]" "$@"
}

cleanup() {
  set +e
  log "Killing ssh agent"
  ssh-agent -k
  log "Removing workspace archive"
  rm -f /tmp/workspace.tar.bz2
}
trap cleanup EXIT

log "Packing workspace into archive to transfer onto remote machine"
tar cjvf /tmp/workspace.tar.bz2 --exclude .git .

log "Registering SSH keys"
mkdir -p "$HOME/.ssh"
printf '%s\n' "$SSH_PRIVATE_KEY" > "$HOME/.ssh/private_key"
chmod 600 "$HOME/.ssh/private_key"

log "Launching ssh agent"
eval "$(ssh-agent)"
ssh-add "$HOME/.ssh/private_key"

log "Adding known hosts"
if [ -n "$SSH_HOST_PUBLIC_KEY" ]; then
  printf '%s %s\n' "$SSH_HOST" "$SSH_HOST_PUBLIC_KEY" >> /etc/ssh/ssh_known_hosts
fi
if [ -n "$SSH_JUMP_PUBLIC_KEY" ]; then
  printf '%s %s\n' "$SSH_JUMP_HOST" "$SSH_JUMP_PUBLIC_KEY" >> /etc/ssh/ssh_known_hosts
fi

remote_path="\$HOME/$WORKSPACE"
remote_cleanup=""
remote_registry_login=""
remote_docker_exec="docker compose -f \"$DOCKER_COMPOSE_FILENAME\" $DOCKER_PRE_ARGS up $DOCKER_ARGS"
if [ -n "$DOCKER_COMPOSE_PREFIX" ]; then
  remote_docker_exec="docker compose -f \"$DOCKER_COMPOSE_FILENAME\" -p \"$DOCKER_COMPOSE_PREFIX\" $DOCKER_PRE_ARGS up $DOCKER_ARGS"
fi
if $DOCKER_USE_STACK ; then
  remote_path="\$HOME/$WORKSPACE/$DOCKER_COMPOSE_PREFIX"
  remote_docker_exec="docker stack deploy -c \"$DOCKER_COMPOSE_FILENAME\" --prune \"$DOCKER_COMPOSE_PREFIX\" $DOCKER_PRE_ARGS $DOCKER_ARGS"
fi
if ! $WORKSPACE_KEEP ; then
  remote_cleanup="cleanup() { log 'Removing workspace'; rm -rf \"$remote_path\"; mkdir -p \"$remote_path\"; }; trap cleanup EXIT;"
fi

if [ -n "$CONTAINER_REGISTRY" ] || [ -n "$CONTAINER_REGISTRY_USERNAME" ] || [ -n "$CONTAINER_REGISTRY_PASSWORD" ]; then
  remote_registry_login="log 'Logging in to container registry...'; docker login -u \"$CONTAINER_REGISTRY_USERNAME\" -p \"$CONTAINER_REGISTRY_PASSWORD\" \"$CONTAINER_REGISTRY\";"
fi

remote_command="set -e;
log() { echo '>> [remote]' \$@ ; };

log 'Creating workspace directory...';
mkdir -p \"$remote_path\";

log 'Unpacking workspace...';
tar -C \"$remote_path\" -xjv;

# Determine the parent directory of remote path
parent_dir=\$(dirname \"$remote_path\")
log 'Parent directory of remote path: ' \$parent_dir

# Check if .env file exists in parent directory of remote path and copy it to remote path
if [ -f \"\$parent_dir/.env\" ]; then
    log 'Copying .env file from parent directory to remote path...';
    cp \"\$parent_dir/.env\" \"$remote_path/\";
fi

$remote_cleanup
$remote_registry_login

log 'Launching docker compose... \"$remote_docker_exec\"';
cd \"$remote_path\";
$DOCKER_ENV $remote_docker_exec"

ssh_jump=""
if [ -n "$SSH_JUMP_HOST" ]; then
  ssh_jump="-J $SSH_USER@$SSH_JUMP_HOST"
fi

echo ">> [local] Connecting to remote host: $SSH_USER@$SSH_HOST:$SSH_PORT."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$SSH_USER@$SSH_HOST" -p "$SSH_PORT" \
  "$remote_command" \
  < /tmp/workspace.tar.bz2
  
