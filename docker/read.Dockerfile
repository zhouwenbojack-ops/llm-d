FROM ubuntu:24.04

ARG DEV_USER=developer
ARG DEV_UID=1000
ARG DEV_GID=1000
ARG PYTHON_VERSION=3.12
ARG UV_VERSION=0.8.17
ARG UV_DEFAULT_INDEX=https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple
ARG KUBECTL_VERSION=v1.35.0
ARG KUSTOMIZE_VERSION=v5.7.1
ARG HELM_VERSION=v3.19.0
ARG KIND_VERSION=v0.31.0
ARG YQ_VERSION=v4.47.2
ARG HADOLINT_VERSION=v2.12.0

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG ALL_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG all_proxy
ARG no_proxy

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/home/${DEV_USER} \
    USER=${DEV_USER} \
    LOGNAME=${DEV_USER} \
    PATH=/opt/uv/bin:${PATH} \
    UV_INSTALL_DIR=/opt/uv/bin \
    UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_CACHE_DIR=/home/${DEV_USER}/.cache/uv \
    UV_LINK_MODE=copy \
    UV_HTTP_TIMEOUT=500 \
    UV_INDEX_STRATEGY=unsafe-best-match \
    UV_DEFAULT_INDEX=${UV_DEFAULT_INDEX} \
    PRE_COMMIT_HOME=/home/${DEV_USER}/.cache/pre-commit

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bash-completion \
        bat \
        build-essential \
        ca-certificates \
        curl \
        docker.io \
        fd-find \
        fzf \
        gettext-base \
        git \
        graphviz \
        jq \
        less \
        lsof \
        make \
        openssh-client \
        python3-dev \
        python3-pip \
        ripgrep \
        shellcheck \
        sudo \
        tar \
        tmux \
        tree \
        universal-ctags \
        unzip \
        vim \
        wget \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "${arch}" in \
        amd64) binary_arch=amd64; hadolint_arch=x86_64 ;; \
        arm64) binary_arch=arm64; hadolint_arch=arm64 ;; \
        *) echo "unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${binary_arch}/kubectl"; \
    curl -fsSLo /usr/local/bin/kind \
        "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${binary_arch}"; \
    curl -fsSLo /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${binary_arch}"; \
    curl -fsSLo /usr/local/bin/hadolint \
        "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/hadolint-Linux-${hadolint_arch}"; \
    curl -fsSL \
        "https://get.helm.sh/helm-${HELM_VERSION}-linux-${binary_arch}.tar.gz" \
        | tar -xz -C /tmp; \
    install -m 0755 "/tmp/linux-${binary_arch}/helm" /usr/local/bin/helm; \
    rm -rf "/tmp/linux-${binary_arch}"; \
    curl -fsSL \
        "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${binary_arch}.tar.gz" \
        | tar -xz -C /usr/local/bin; \
    chmod 0755 \
        /usr/local/bin/hadolint \
        /usr/local/bin/kind \
        /usr/local/bin/kubectl \
        /usr/local/bin/kustomize \
        /usr/local/bin/yq; \
    kubectl version --client=true; \
    kustomize version; \
    helm version --short; \
    kind version; \
    yq --version; \
    hadolint --version

RUN set -eux; \
    group_name="$(getent group "${DEV_GID}" | cut -d: -f1 || true)"; \
    if [ -z "${group_name}" ]; then \
        group_name="${DEV_USER}"; \
        groupadd --gid "${DEV_GID}" "${group_name}"; \
    fi; \
    useradd --create-home --shell /bin/bash --uid "${DEV_UID}" \
        --gid "${group_name}" "${DEV_USER}"; \
    install -d -o "${DEV_UID}" -g "${DEV_GID}" \
        "/home/${DEV_USER}/.cache/pre-commit" \
        "/home/${DEV_USER}/.cache/uv" \
        /opt/uv; \
    echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${DEV_USER}"; \
    chmod 0440 "/etc/sudoers.d/${DEV_USER}"

RUN test "$(python3 --version | cut -d ' ' -f 2 | cut -d. -f1,2)" = \
        "${PYTHON_VERSION}" \
    && python3 -m pip install \
        --break-system-packages \
        --no-cache-dir \
        --index-url "${UV_DEFAULT_INDEX}" \
        "uv==${UV_VERSION}" \
    && uv --version \
    && chown -R "${DEV_UID}:${DEV_GID}" /opt/uv

COPY --chown=${DEV_UID}:${DEV_GID} docker/read.bashrc.template \
    /home/${DEV_USER}/.bashrc

USER ${DEV_USER}
WORKDIR /workspace

CMD ["sleep", "infinity"]
