#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WORKSPACE_DIR="${DEV_WORKSPACE_DIR:-${SCRIPT_DIR}}"
DEV_USER="${DEV_CONTAINER_USER:-developer}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

[[ -d "${WORKSPACE_DIR}" ]] || {
  printf 'Error: workspace does not exist: %s\n' "${WORKSPACE_DIR}" >&2
  exit 1
}
WORKSPACE_DIR="$(cd -- "${WORKSPACE_DIR}" && pwd -P)"

PROJECT_NAME="${SCRIPT_DIR##*/}"
PROJECT_NAME="$(printf '%s' "${PROJECT_NAME}" |
  tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-')"
PROJECT_KEY="$(printf '%s' "${WORKSPACE_DIR}" | cksum | awk '{print $1}')"

IMAGE_NAME="${DEV_IMAGE_NAME:-${PROJECT_NAME}-read:ubuntu24.04}"
CONTAINER_NAME="${DEV_CONTAINER_NAME:-${PROJECT_NAME}-read-${PROJECT_KEY}}"
DOCKERFILE="${SCRIPT_DIR}/docker/read.Dockerfile"
UV_CACHE_HOST_DIR="${DEV_UV_CACHE_DIR:-${HOME}/.cache/${PROJECT_NAME}-uv}"
PRE_COMMIT_CACHE_HOST_DIR="${DEV_PRE_COMMIT_CACHE_DIR:-${HOME}/.cache/${PROJECT_NAME}-pre-commit}"
VENV_DIR="${DEV_VENV_DIR:-${WORKSPACE_DIR}/.venv-linux}"
if [[ "${VENV_DIR}" != /* ]]; then
  VENV_DIR="${WORKSPACE_DIR}/${VENV_DIR}"
fi
PYTHON_BIN="${VENV_DIR}/bin/python"

if [[ -n "${DEV_DOCKER_PLATFORM:-}" ]]; then
  DOCKER_PLATFORM="${DEV_DOCKER_PLATFORM}"
elif [[ "$(uname -m)" == "arm64" ]]; then
  DOCKER_PLATFORM="linux/arm64"
else
  DOCKER_PLATFORM="linux/amd64"
fi
TARGET_ARCH="${DEV_TARGET_ARCH:-${DOCKER_PLATFORM#linux/}}"

log() {
  printf '[llm-d-dev] %s\n' "$*"
}

die() {
  printf '[llm-d-dev] Error: %s\n' "$*" >&2
  exit 1
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker command was not found"
  docker info >/dev/null 2>&1 ||
    die "Docker daemon is not running or is not accessible"
}

container_exists() {
  docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1
}

container_running() {
  [[ "$(docker inspect --format '{{.State.Running}}' \
    "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]]
}

image_exists() {
  docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1
}

container_uses_current_image() {
  [[ "$(docker inspect --format '{{.Image}}' \
    "${CONTAINER_NAME}" 2>/dev/null || true)" == \
    "$(docker image inspect --format '{{.Id}}' \
      "${IMAGE_NAME}" 2>/dev/null || true)" ]]
}

git_common_dir() {
  local common_dir
  common_dir="$(git -C "${WORKSPACE_DIR}" rev-parse \
    --git-common-dir 2>/dev/null || true)"
  [[ -n "${common_dir}" ]] || return 0

  if [[ "${common_dir}" != /* ]]; then
    common_dir="${WORKSPACE_DIR}/${common_dir}"
  fi
  (cd -- "${common_dir}" && pwd -P)
}

docker_socket_path() {
  local context
  local endpoint

  context="$(docker context show 2>/dev/null || true)"
  if [[ "${context}" == "colima" ]]; then
    printf '%s' /var/run/docker.sock
    return
  fi

  endpoint="$(docker context inspect \
    --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
  case "${endpoint}" in
    unix://*) printf '%s' "${endpoint#unix://}" ;;
    *) [[ -S /var/run/docker.sock ]] && printf '%s' /var/run/docker.sock ;;
  esac
}

docker_socket_gid() {
  local socket="$1"

  if [[ -S "${socket}" ]]; then
    stat -f '%g' "${socket}" 2>/dev/null ||
      stat -c '%g' "${socket}" 2>/dev/null
    return
  fi

  docker run --rm \
    --platform "${DOCKER_PLATFORM}" \
    --volume "${socket}:/var/run/docker.sock" \
    --entrypoint stat \
    "${IMAGE_NAME}" \
    -c '%g' /var/run/docker.sock
}

proxy_value() {
  local name="$1"
  local value

  case "${name}" in
    HTTP_PROXY)
      value="${DEV_HTTP_PROXY:-${HTTP_PROXY:-${http_proxy:-}}}"
      ;;
    HTTPS_PROXY)
      value="${DEV_HTTPS_PROXY:-${HTTPS_PROXY:-${https_proxy:-}}}"
      ;;
    ALL_PROXY)
      value="${DEV_ALL_PROXY:-${ALL_PROXY:-${all_proxy:-}}}"
      ;;
    NO_PROXY)
      value="${DEV_NO_PROXY:-${NO_PROXY:-${no_proxy:-}}}"
      printf '%s' "${value}"
      return
      ;;
  esac

  value="${value/127.0.0.1/host.docker.internal}"
  value="${value/localhost/host.docker.internal}"
  printf '%s' "${value}"
}

build_image() {
  local name
  local value
  local -a build_args

  require_docker
  [[ -f "${DOCKERFILE}" ]] || die "cannot find ${DOCKERFILE}"

  build_args=(
    --build-arg "PYTHON_VERSION=${DEV_PYTHON_VERSION:-3.12}"
  )
  for name in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    value="$(proxy_value "${name}")"
    if [[ -n "${value}" ]]; then
      build_args+=(--build-arg "${name}=${value}")
      build_args+=(--build-arg "$(printf '%s' "${name}" |
        tr '[:upper:]' '[:lower:]')=${value}")
    fi
  done
  [[ -z "${DEV_UV_DEFAULT_INDEX:-}" ]] ||
    build_args+=(--build-arg "UV_DEFAULT_INDEX=${DEV_UV_DEFAULT_INDEX}")

  log "Building ${IMAGE_NAME} (${DOCKER_PLATFORM})"
  docker build \
    --platform "${DOCKER_PLATFORM}" \
    --build-arg "DEV_USER=${DEV_USER}" \
    --build-arg "DEV_UID=${HOST_UID}" \
    --build-arg "DEV_GID=${HOST_GID}" \
    --tag "${IMAGE_NAME}" \
    --file "${DOCKERFILE}" \
    "${build_args[@]}" \
    "$@" \
    "${SCRIPT_DIR}"
}

create_container() {
  local common_dir
  local docker_socket
  local docker_socket_group
  local name
  local value
  local -a run_args

  image_exists || build_image
  mkdir -p -- \
    "${UV_CACHE_HOST_DIR}" \
    "${PRE_COMMIT_CACHE_HOST_DIR}" \
    "${VENV_DIR}"

  run_args=(
    run --detach --init
    --name "${CONTAINER_NAME}"
    --hostname "${PROJECT_NAME}-read"
    --platform "${DOCKER_PLATFORM}"
    --workdir "${WORKSPACE_DIR}"
    --label "dev.workspace=${WORKSPACE_DIR}"
    --env "DEVCONTAINER=1"
    --env "VIRTUAL_ENV=${VENV_DIR}"
    --env "PATH=${VENV_DIR}/bin:/opt/uv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    --env "UV_CACHE_DIR=/home/${DEV_USER}/.cache/uv"
    --env "PRE_COMMIT_HOME=/home/${DEV_USER}/.cache/pre-commit"
    --volume "${WORKSPACE_DIR}:${WORKSPACE_DIR}"
    --volume "${UV_CACHE_HOST_DIR}:/home/${DEV_USER}/.cache/uv"
    --volume "${PRE_COMMIT_CACHE_HOST_DIR}:/home/${DEV_USER}/.cache/pre-commit"
  )

  for name in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    value="$(proxy_value "${name}")"
    if [[ -n "${value}" ]]; then
      run_args+=(--env "${name}=${value}")
      run_args+=(--env "$(printf '%s' "${name}" |
        tr '[:upper:]' '[:lower:]')=${value}")
    fi
  done

  common_dir="$(git_common_dir)"
  case "${common_dir}" in
    ""|"${WORKSPACE_DIR}"|"${WORKSPACE_DIR}"/*) ;;
    *) run_args+=(--volume "${common_dir}:${common_dir}") ;;
  esac

  docker_socket="$(docker_socket_path)"
  if [[ "${DEV_MOUNT_DOCKER_SOCKET:-1}" == "1" &&
    -n "${docker_socket}" ]]; then
    run_args+=(--volume "${docker_socket}:/var/run/docker.sock")
    docker_socket_group="$(docker_socket_gid "${docker_socket}")"
    [[ -z "${docker_socket_group}" ]] ||
      run_args+=(--group-add "${docker_socket_group}")
  fi
  if [[ "${DEV_MOUNT_KUBE_CONFIG:-0}" == "1" && -d "${HOME}/.kube" ]]; then
    run_args+=(--volume "${HOME}/.kube:/home/${DEV_USER}/.kube")
  fi

  run_args+=(--add-host "host.docker.internal:host-gateway" "${IMAGE_NAME}")
  docker "${run_args[@]}" >/dev/null

  if [[ -n "${docker_socket_group}" ]]; then
    docker exec --user root "${CONTAINER_NAME}" sh -c \
      'getent group "$1" >/dev/null || groupadd --gid "$1" docker-host' \
      sh "${docker_socket_group}"
  fi
  if git -C "${WORKSPACE_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
    docker exec "${CONTAINER_NAME}" git config --global \
      --add safe.directory "${WORKSPACE_DIR}"
  fi
  log "Container started: ${CONTAINER_NAME}"
}

start_container() {
  require_docker
  if container_exists && image_exists && ! container_uses_current_image; then
    die "container uses an old image; run ./env.sh rebuild"
  fi
  if container_running; then
    log "Container is already running: ${CONTAINER_NAME}"
  elif container_exists; then
    docker start "${CONTAINER_NAME}" >/dev/null
    log "Container started: ${CONTAINER_NAME}"
  else
    create_container
  fi
}

ensure_running() {
  if container_exists && image_exists && ! container_uses_current_image; then
    die "container uses an old image; run ./env.sh rebuild"
  fi
  container_running || start_container
}

remove_container() {
  require_docker
  if container_exists; then
    docker rm --force "${CONTAINER_NAME}" >/dev/null
    log "Container removed; source and caches were preserved"
  else
    log "Container does not exist: ${CONTAINER_NAME}"
  fi
}

open_shell() {
  ensure_running
  docker exec \
    --interactive --tty \
    --env "TERM=${TERM:-xterm-256color}" \
    --env "COLORTERM=${COLORTERM:-truecolor}" \
    --workdir "${WORKSPACE_DIR}" \
    "${CONTAINER_NAME}" bash --login
}

exec_in_container() {
  ensure_running
  docker exec --workdir "${WORKSPACE_DIR}" "${CONTAINER_NAME}" "$@"
}

setup_python() {
  ensure_running
  if ! docker exec "${CONTAINER_NAME}" test -x "${PYTHON_BIN}"; then
    log "Creating the Python 3.12 environment"
    docker exec \
      --workdir "${WORKSPACE_DIR}" \
      "${CONTAINER_NAME}" \
      uv venv --python 3.12 --seed "${VENV_DIR}"
  fi

  log "Installing repository development dependencies"
  docker exec \
    --workdir "${WORKSPACE_DIR}" \
    "${CONTAINER_NAME}" \
    uv pip install \
      --python "${PYTHON_BIN}" \
      "pyyaml==6.*" \
      pytest \
      pre-commit

  log "Python interpreter: ${PYTHON_BIN}"
}

run_checks() {
  setup_python
  exec_in_container make verify
  exec_in_container "${PYTHON_BIN}" -m pytest scripts/tests helpers/smoke-test/tests
  exec_in_container "${PYTHON_BIN}" -m unittest discover \
    -t . -s docker/scripts/snapshot
}

run_lint() {
  setup_python
  exec_in_container "${VENV_DIR}/bin/pre-commit" run --all-files "$@"
}

compile_cpu_image() {
  ensure_running
  log "Building the llm-d CPU image from source for linux/${TARGET_ARCH}"
  exec_in_container make image-build \
    DEVICE=cpu \
    ARCH="${TARGET_ARCH}" \
    OS=ubuntu \
    BUILD_TYPE=dev \
    "$@"
}

show_status() {
  local image_sync="n/a"

  require_docker
  if container_exists && image_exists; then
    image_sync="$(container_uses_current_image && printf yes || printf no)"
  fi
  printf 'container:         %s\n' "${CONTAINER_NAME}"
  printf 'running:           %s\n' "$(container_running && printf yes || printf no)"
  printf 'image:             %s\n' "${IMAGE_NAME}"
  printf 'image sync:        %s\n' "${image_sync}"
  printf 'platform:          %s\n' "${DOCKER_PLATFORM}"
  printf 'target arch:       %s\n' "${TARGET_ARCH}"
  printf 'workspace:         %s\n' "${WORKSPACE_DIR}"
  printf 'python:            %s\n' "${PYTHON_BIN}"
  printf 'uv cache:          %s\n' "${UV_CACHE_HOST_DIR}"
  printf 'pre-commit cache:  %s\n' "${PRE_COMMIT_CACHE_HOST_DIR}"
}

usage() {
  cat <<'EOF'
Usage: ./env.sh <command> [arguments]

  up                    Create or start the development container
  shell                 Open an interactive Bash shell
  exec <command...>     Run a non-interactive command in the workspace
  build [Docker args]   Build the development image
  rebuild               Rebuild the image and recreate the container
  setup                 Create the Python environment and install dev tools
  ide                   Prepare the Python interpreter for IDE navigation
  check                 Run repository verification and Python tests
  lint [pre-commit args]
                        Run all repository pre-commit hooks
  compile [make vars]   Build the llm-d CPU image from source
  status                Show the current configuration
  down                  Remove the container, preserving source and caches
  help                  Show this help

Environment overrides:
  DEV_WORKSPACE_DIR, DEV_IMAGE_NAME, DEV_CONTAINER_NAME,
  DEV_CONTAINER_USER, DEV_DOCKER_PLATFORM, DEV_TARGET_ARCH,
  DEV_UV_CACHE_DIR, DEV_PRE_COMMIT_CACHE_DIR, DEV_VENV_DIR,
  DEV_MOUNT_DOCKER_SOCKET, DEV_MOUNT_KUBE_CONFIG,
  DEV_HTTP_PROXY, DEV_HTTPS_PROXY, DEV_ALL_PROXY, DEV_NO_PROXY,
  DEV_UV_DEFAULT_INDEX, DEV_PYTHON_VERSION

Set DEV_MOUNT_KUBE_CONFIG=1 only when cluster access is needed. The host
Docker socket is mounted by default so `compile` can use Docker BuildKit.
EOF
}

command_name="${1:-shell}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "${command_name}" in
  up)
    start_container
    ;;
  shell)
    open_shell
    ;;
  exec)
    [[ $# -gt 0 ]] || die "exec requires a command"
    exec_in_container "$@"
    ;;
  build)
    build_image "$@"
    ;;
  rebuild)
    remove_container
    build_image
    create_container
    ;;
  setup|ide)
    setup_python
    ;;
  check)
    run_checks
    ;;
  lint)
    run_lint "$@"
    ;;
  compile)
    compile_cpu_image "$@"
    ;;
  status)
    show_status
    ;;
  down)
    remove_container
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    die "unknown command: ${command_name}"
    ;;
esac
