#!/bin/bash

__dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$__dir/helper.sh"

APP_DIR="$GITHUB_WORKSPACE"

[[ -d "${APP_DIR:-}" ]] || emergency "$APP_DIR path doesn't exits. Aborting.."

setup_basic() {
    info "Init and Validations: Started"
    hosts_file="$GITHUB_WORKSPACE/.github/hosts.yml"
    REMOTE_USER=$(shyaml get-value "${GITHUB_BRANCH}.user" <"$hosts_file" 2>/dev/null || true)
    REMOTE_HOST=$(shyaml get-value "${GITHUB_BRANCH}.hostname" <"$hosts_file" 2>/dev/null  || true)
    REMOTE_PATH=$(shyaml get-value "${GITHUB_BRANCH}.deploy_path" <"$hosts_file" 2>/dev/null  || true)
    RELEASES_LIMIT=$(shyaml get-value "${GITHUB_BRANCH}.prev_releases_limit" <"$hosts_file" 2>/dev/null  || true)

    [[ "${REMOTE_HOST:-}" ]] || emergency "The variable ${CYAN} hostname ${ENDCOLOR} is missing in hosts.yml"
    [[ "${REMOTE_USER:-}" ]] || emergency "The vairable ${CYAN} user ${ENDCOLOR} is missing in hosts.yml"
    [[ "${REMOTE_PATH:-}" ]] || emergency "The variable ${CYAN} deploy_path ${ENDCOLOR} is missing in hosts.yml"

    # remove leading slash
    REMOTE_PATH="${REMOTE_PATH%/}"

    setup_ssh

    ssh-keyscan -H "$REMOTE_HOST" >>/etc/ssh/ssh_known_hosts 2>/dev/null

    APP_PATH="${REMOTE_PATH}/app"
    RELEASE_FOLDER_NAME="releases/$(date +'%d-%b-%Y--%H-%M')"
    APP_REMOTE_RELEASE_PATH="${REMOTE_PATH}/app/${RELEASE_FOLDER_NAME}"

    info "Init and Validations: Everything looks good !"
}

handle_before_build() {
    # create folder
    cd ~/
    mkdir -p "$RELEASE_FOLDER_NAME"
    rsync -azh "${APP_DIR}/" "${RELEASE_FOLDER_NAME}/"
}

handle_release(){
    info "Sync code with server: Started"
    remote_execute "$REMOTE_PATH" "mkdir -p ${REMOTE_PATH}/app/releases"
    rsync -azh "${RELEASE_FOLDER_NAME}" "$REMOTE_USER"@"$REMOTE_HOST":"$REMOTE_PATH/app/releases/"
    info "Sync code with server: Completed"
}

maybe_install_node_dep() {

    if [[ -n "$NODE_VERSION" ]]; then
        echo "Setting up $NODE_VERSION"
        NVM_LATEST_VER=$(curl -s "https://api.github.com/repos/nvm-sh/nvm/releases/latest" |
            grep '"tag_name":' |
            sed -E 's/.*"([^"]+)".*/\1/') &&
            curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_LATEST_VER/install.sh" | bash

        export NVM_DIR="$([[ -z "${XDG_CONFIG_HOME-}" ]] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"

        [[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh" || true

        nvm install "$NODE_VERSION"
        nvm use "$NODE_VERSION"

    echo "Installed Node Version -> $(node --version)"
    fi
}

handle_build_server() {
    # building the app

    cd ~/"${RELEASE_FOLDER_NAME}"

    git config --global --add safe.directory "${PWD}"

    NODE_VERSION=18

    echo "::group::Node Installation -> $NODE_VERSION log."
    maybe_install_node_dep
    echo "::endgroup::"

    info "App Build: Started"
    echo "::group::App Build log."
    npm ci
    sys_ram=$(free --mega | grep -i mem | awk '{print $2}')
    node_ram=$(( "${sys_ram}" - 1000 ))
    export NODE_OPTIONS="--max-old-space-size=$node_ram"
    npm run production
    BUILD_STATUS="$?"
    echo "::endgroup::"
    # check if build was successful
    if [[ "$BUILD_STATUS" -gt 0 ]]; then
        error "App Build: Failed"
        exit 1
    else
        info "App Build: Successful"
    fi

    cd ~/
}

handle_after_release() {
    info "Symlink latest deployment."
    remote_execute "$APP_PATH" "ln -sfn $RELEASE_FOLDER_NAME current"
    info "Restarting server"
    remote_execute "$REMOTE_PATH" 'docker compose restart server'
}

retain_releases() {
    echo "::group::Cleanup Releases."
    if [[ "${RELEASES_LIMIT:-}" ]]; then
        info "Removing redundant previous releases"
        info "Retain only -> $RELEASES_LIMIT releases"
        list_of_releases=$(remote_execute "${APP_PATH}/releases" "ls -1t")
        RELEASES_LIMIT=$(("$RELEASES_LIMIT" + 1))
        to_remove_dirs=$(tail +$RELEASES_LIMIT <<<"$list_of_releases")

        for dir in $to_remove_dirs; do
            info "Removing dir -> $dir"
            remote_execute "${APP_PATH}/releases" "rm -rf $dir"
        done
    fi
    echo "::endgroup::"
}

function main() {
    setup_basic
    handle_before_build
    handle_build_server
    handle_release
    handle_after_release
    retain_releases
}

main
