#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Disable prompts for apt-get.
export DEBIAN_FRONTEND="noninteractive"

# System info.
PLATFORM="$(uname --hardware-platform || true)"
DISTRIB_CODENAME="$(lsb_release --codename --short || true)"
DISTRIB_ID="$(lsb_release --id --short | tr '[:upper:]' '[:lower:]' || true)"

# Secure generator comands
GENERATE_SECURE_SECRET_CMD="openssl rand --hex 16"
GENERATE_K256_PRIVATE_KEY_CMD="openssl ecparam --name secp256k1 --genkey --noout --outform DER | tail --bytes=+8 | head --bytes=32 | xxd --plain --cols 32"

# Source location
SOURCE_URL="https://github.com/sacckey/feed-generator.git"

# System dependencies.
REQUIRED_SYSTEM_PACKAGES="
  ca-certificates
  curl
  gnupg
  lsb-release
  openssl
  xxd
  git
"
# Docker packages.
REQUIRED_DOCKER_PACKAGES="
  docker-ce
  docker-ce-cli
  docker-compose-plugin
  containerd.io
"

PUBLIC_IP=""
METADATA_URLS=()
METADATA_URLS+=("http://169.254.169.254/v1/interfaces/0/ipv4/address") # Vultr
METADATA_URLS+=("http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address") # DigitalOcean
METADATA_URLS+=("http://169.254.169.254/2021-03-23/meta-data/public-ipv4") # AWS
METADATA_URLS+=("http://169.254.169.254/hetzner/v1/metadata/public-ipv4") # Hetzner

FEEDGEN_DATADIR="${1:-/feedgen}"
FEEDGEN_HOSTNAME="${2:-}"
FEEDGEN_ADMIN_EMAIL="${3:-}"
FEEDGEN_SUBSCRIPTION_ENDPOINT="${4:-}"
FEEDGEN_PUBLISHER_DID="${5:-}"

function usage {
  local error="${1}"
  cat <<USAGE >&2
ERROR: ${error}
Usage:
sudo bash $0

Please try again.
USAGE
  exit 1
}

function main {
  # Check that user is root.
  if [[ "${EUID}" -ne 0 ]]; then
    usage "This script must be run as root. (e.g. sudo $0)"
  fi

  # Check for a supported architecture.
  # If the platform is unknown (not uncommon) then we assume x86_64
  if [[ "${PLATFORM}" == "unknown" ]]; then
    PLATFORM="x86_64"
  fi
  if [[ "${PLATFORM}" != "x86_64" ]] && [[ "${PLATFORM}" != "aarch64" ]] && [[ "${PLATFORM}" != "arm64" ]]; then
    usage "Sorry, only x86_64 and aarch64/arm64 are supported. Exiting..."
  fi

  # Check for a supported distribution.
  SUPPORTED_OS="false"
  if [[ "${DISTRIB_ID}" == "ubuntu" ]]; then
    if [[ "${DISTRIB_CODENAME}" == "focal" ]]; then
      SUPPORTED_OS="true"
      echo "* Detected supported distribution Ubuntu 20.04 LTS"
    elif [[ "${DISTRIB_CODENAME}" == "jammy" ]]; then
      SUPPORTED_OS="true"
      echo "* Detected supported distribution Ubuntu 22.04 LTS"
    fi
  elif [[ "${DISTRIB_ID}" == "debian" ]]; then
    if [[ "${DISTRIB_CODENAME}" == "bullseye" ]]; then
      SUPPORTED_OS="true"
      echo "* Detected supported distribution Debian 11"
    elif [[ "${DISTRIB_CODENAME}" == "bookworm" ]]; then
      SUPPORTED_OS="true"
      echo "* Detected supported distribution Debian 12"
    fi
  fi

  if [[ "${SUPPORTED_OS}" != "true" ]]; then
    echo "Sorry, only Ubuntu 20.04, 22.04, Debian 11 and Debian 12 are supported by this installer. Exiting..."
    exit 1
  fi

  # Check if feed generator is already installed.
  if [[ -e "${FEEDGEN_DATADIR}/feedgen.sqlite" ]]; then
    echo
    echo "ERROR: feedgen is already configured in ${FEEDGEN_DATADIR}"
    echo
    echo "To do a clean re-install:"
    echo "------------------------------------"
    echo "1. Stop the service"
    echo
    echo "  sudo systemctl stop feedgen"
    echo
    echo "2. Delete the data directory"
    echo
    echo "  sudo rm -rf ${FEEDGEN_DATADIR}"
    echo
    echo "3. Re-run this installation script"
      echo
    echo "  sudo bash ${0}"
    echo
    echo "For assistance, check https://github.com/bluesky-social/feed-generator"
    exit 1
  fi


  #
  # Attempt to determine server's public IP.
  #

  # First try using the hostname command, which usually works.
  if [[ -z "${PUBLIC_IP}" ]]; then
    PUBLIC_IP=$(hostname --all-ip-addresses | awk '{ print $1 }')
  fi

  # Prevent any private IP address from being used, since it won't work.
  if [[ "${PUBLIC_IP}" =~ ^(127\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.) ]]; then
    PUBLIC_IP=""
  fi

  # Check the various metadata URLs.
  if [[ -z "${PUBLIC_IP}" ]]; then
    for METADATA_URL in "${METADATA_URLS[@]}"; do
      METADATA_IP="$(timeout 2 curl --silent --show-error "${METADATA_URL}" | head --lines=1 || true)"
      if [[ "${METADATA_IP}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        PUBLIC_IP="${METADATA_IP}"
        break
      fi
    done
  fi

  if [[ -z "${PUBLIC_IP}" ]]; then
    PUBLIC_IP="Server's IP"
  fi

  #
  # Prompt user for required variables.
  #
  if [[ -z "${FEEDGEN_HOSTNAME}" ]]; then
    cat <<INSTALLER_MESSAGE
---------------------------------------
     Add DNS Record for Public IP
---------------------------------------

  From your DNS provider's control panel, create the required
  DNS record with the value of your server's public IP address.

  + Any DNS name that can be resolved on the public internet will work.
  + Replace example.com below with any valid domain name you control.
  + A TTL of 600 seconds (10 minutes) is recommended.

  Example DNS record:

    NAME                TYPE   VALUE
    ----                ----   -----
    example.com         A      ${PUBLIC_IP:-Server public IP}

  **IMPORTANT**
  It's recommended to wait 3-5 minutes after creating a new DNS record
  before attempting to use it. This will allow time for the DNS record
  to be fully updated.

INSTALLER_MESSAGE

    if [[ -z "${FEEDGEN_HOSTNAME}" ]]; then
      read -p "Enter your public DNS address (e.g. example.com): " FEEDGEN_HOSTNAME
    fi
  fi

  if [[ -z "${FEEDGEN_HOSTNAME}" ]]; then
    usage "No public DNS address specified"
  fi

  if [[ "${FEEDGEN_HOSTNAME}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    usage "Invalid public DNS address (must not be an IP address)"
  fi

  # Admin email
  if [[ -z "${FEEDGEN_ADMIN_EMAIL}" ]]; then
    read -p "Enter an admin email address (e.g. you@example.com): " FEEDGEN_ADMIN_EMAIL
  fi
  if [[ -z "${FEEDGEN_ADMIN_EMAIL}" ]]; then
    usage "No admin email specified"
  fi

  if [[ -z "${FEEDGEN_ADMIN_EMAIL}" ]]; then
    read -p "Enter an admin email address (e.g. you@example.com): " FEEDGEN_ADMIN_EMAIL
  fi
  if [[ -z "${FEEDGEN_ADMIN_EMAIL}" ]]; then
    usage "No admin email specified"
  fi

  # Subscription endpoint
  if [[ -z "${FEEDGEN_SUBSCRIPTION_ENDPOINT}" ]]; then
    read -p "Enter an subscription endpoint (e.g. wss://bsky.social): " FEEDGEN_SUBSCRIPTION_ENDPOINT
  fi
  if [[ -z "${FEEDGEN_SUBSCRIPTION_ENDPOINT}" ]]; then
    usage "No subscription endpoint specified"
  fi

  if [[ -z "${FEEDGEN_SUBSCRIPTION_ENDPOINT}" ]]; then
    read -p "Enter an subscription endpoint (e.g. wss://bsky.social): " FEEDGEN_SUBSCRIPTION_ENDPOINT
  fi
  if [[ -z "${FEEDGEN_SUBSCRIPTION_ENDPOINT}" ]]; then
    usage "No subscription endpoint specified"
  fi

  # Feedgen publisher did
  if [[ -z "${FEEDGEN_PUBLISHER_DID}" ]]; then
    read -p "Enter an Feedgen publisher did (e.g. did:plc:abcde....): " FEEDGEN_PUBLISHER_DID
  fi
  if [[ -z "${FEEDGEN_PUBLISHER_DID}" ]]; then
    usage "No Feedgen publisher did specified"
  fi

  if [[ -z "${FEEDGEN_PUBLISHER_DID}" ]]; then
    read -p "Enter an Feedgen publisher did (e.g. did:plc:abcde....): " FEEDGEN_PUBLISHER_DID
  fi
  if [[ -z "${FEEDGEN_PUBLISHER_DID}" ]]; then
    usage "No Feedgen publisher did specified"
  fi


  #
  # Install system packages.
  #
  if lsof -v >/dev/null 2>&1; then
    while true; do
      apt_process_count="$(lsof -n -t /var/cache/apt/archives/lock /var/lib/apt/lists/lock /var/lib/dpkg/lock | wc --lines || true)"
      if (( apt_process_count == 0 )); then
        break
      fi
      echo "* Waiting for other apt process to complete..."
      sleep 2
    done
  fi

  apt-get update
  apt-get install --yes ${REQUIRED_SYSTEM_PACKAGES}

  #
  # Install Docker
  #
  if ! docker version >/dev/null 2>&1; then
    echo "* Installing Docker"
    mkdir --parents /etc/apt/keyrings

    # Remove the existing file, if it exists,
    # so there's no prompt on a second run.
    rm --force /etc/apt/keyrings/docker.gpg
    curl --fail --silent --show-error --location "https://download.docker.com/linux/${DISTRIB_ID}/gpg" | \
      gpg --dearmor --output /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRIB_ID} ${DISTRIB_CODENAME} stable" >/etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install --yes ${REQUIRED_DOCKER_PACKAGES}
  fi

  #
  # Configure the Docker daemon so that logs don't fill up the disk.
  #
  if ! [[ -e /etc/docker/daemon.json ]]; then
    echo "* Configuring Docker daemon"
    cat <<'DOCKERD_CONFIG' >/etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "500m",
    "max-file": "4"
  }
}
DOCKERD_CONFIG
    systemctl restart docker
  else
    echo "* Docker daemon already configured! Ensure log rotation is enabled."
  fi

  #
  # Create data directory.
  #
  if ! [[ -d "${FEEDGEN_DATADIR}" ]]; then
    echo "* Creating data directory ${FEEDGEN_DATADIR}"
    mkdir --parents "${FEEDGEN_DATADIR}"
  fi
  chmod 700 "${FEEDGEN_DATADIR}"

  #
  # Download and install feedgen launcher.
  #
  echo "* Downloading feed generator sources"
  git clone -b docker "${SOURCE_URL}" "${FEEDGEN_DATADIR}"

  # Replace the /feedgen paths with the ${FEEDGEN_DATADIR} path.
  sed --in-place "s|/feedgen|${FEEDGEN_DATADIR}|g" "${FEEDGEN_DATADIR}/docker-compose.yml"

  #
  # Configure Caddy
  #
  if ! [[ -d "${FEEDGEN_DATADIR}/caddy/data" ]]; then
    echo "* Creating Caddy data directory"
    mkdir --parents "${FEEDGEN_DATADIR}/caddy/data"
  fi
  if ! [[ -d "${FEEDGEN_DATADIR}/caddy/etc/caddy" ]]; then
    echo "* Creating Caddy config directory"
    mkdir --parents "${FEEDGEN_DATADIR}/caddy/etc/caddy"
  fi

  echo "* Creating Caddy config file"
  cat <<CADDYFILE >"${FEEDGEN_DATADIR}/caddy/etc/caddy/Caddyfile"
{
	email ${FEEDGEN_ADMIN_EMAIL}
	on_demand_tls {
		ask http://localhost:3000/.well-known/did.json
	}
}

${FEEDGEN_HOSTNAME} {
	tls {
		on_demand
	}
	reverse_proxy http://localhost:3000
}
CADDYFILE

  #
  # Create the feed generator env config
  #
  cat <<FEEDGEN_CONFIG >"${FEEDGEN_DATADIR}/.env"
# Whichever port you want to run this on
FEEDGEN_PORT=3000

# Change this to use a different bind address
FEEDGEN_LISTENHOST=localhost

# Set to something like db.sqlite to store persistently
FEEDGEN_SQLITE_LOCATION=${FEEDGEN_DATADIR}/feedgen.sqlite

# Don't change unless you're working in a different environment than the primary Bluesky network
FEEDGEN_SUBSCRIPTION_ENDPOINT=${FEEDGEN_SUBSCRIPTION_ENDPOINT}

# Set this to the hostname that you intend to run the service at
FEEDGEN_HOSTNAME=${FEEDGEN_HOSTNAME}

# Set this to the DID of the account you'll use to publish the feed
# You can find your accounts DID by going to
# https://bsky.social/xrpc/com.atproto.identity.resolveHandle?handle=YOUR_HANDLE
FEEDGEN_PUBLISHER_DID=${FEEDGEN_PUBLISHER_DID}

# Only use this if you want a service did different from did:web
# FEEDGEN_SERVICE_DID="did:plc:abcde..."

# Delay between reconnect attempts to the firehose subscription endpoint (in milliseconds)
FEEDGEN_SUBSCRIPTION_RECONNECT_DELAY=3000

FEEDGEN_CONFIG

  #
  # Create the systemd service.
  #
  echo "* Starting the feedgen systemd service"
  cat <<SYSTEMD_UNIT_FILE >/etc/systemd/system/feedgen.service
[Unit]
Description=Bluesky Feed Generator Service
Documentation=https://github.com/bluesky-social/feed-generator
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${FEEDGEN_DATADIR}
ExecStart=/usr/bin/docker compose --file ${FEEDGEN_DATADIR}/docker-compose.yml up --detach
ExecStop=/usr/bin/docker compose --file ${FEEDGEN_DATADIR}/docker-compose.yml down

[Install]
WantedBy=default.target
SYSTEMD_UNIT_FILE

  systemctl daemon-reload
  systemctl enable feedgen
  systemctl restart feedgen

  # Enable firewall access if ufw is in use.
  if ufw status >/dev/null 2>&1; then
    if ! ufw status | grep --quiet '^80[/ ]'; then
      echo "* Enabling access on TCP port 80 using ufw"
      ufw allow 80/tcp >/dev/null
    fi
    if ! ufw status | grep --quiet '^443[/ ]'; then
      echo "* Enabling access on TCP port 443 using ufw"
      ufw allow 443/tcp >/dev/null
    fi
  fi

  cat <<INSTALLER_MESSAGE
========================================================================
Feed generator installation successful!
------------------------------------------------------------------------

Check service status      : sudo systemctl status feedgen
Watch service logs        : sudo docker logs -f feedgen
Backup service data       : ${FEEDGEN_DATADIR}

Required Firewall Ports
------------------------------------------------------------------------
Service                Direction  Port   Protocol  Source
-------                ---------  ----   --------  ----------------------
HTTP TLS verification  Inbound    80     TCP       Any
HTTP Control Panel     Inbound    443    TCP       Any

Required DNS entries
------------------------------------------------------------------------
Name                         Type       Value
-------                      ---------  ---------------
${FEEDGEN_HOSTNAME}              A          ${PUBLIC_IP}

Detected public IP of this server: ${PUBLIC_IP}

========================================================================
INSTALLER_MESSAGE
}

# Run main function.
main
