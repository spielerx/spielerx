#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

show_menu() {
    clear
    echo "=========================================="
    echo "       Ubuntu Server Setup Tool"
    echo "=========================================="
    echo "1) Setup SSH Key Authentication Only"
    echo "2) Configure Swap File"
    echo "3) Setup VPN Connection"
    echo "4) Install Docker & Docker Compose"
    echo "5) Install Dokploy"
    echo "6) Security Hardening"
    echo "7) Install & Configure Squid Proxy"
    echo "8) Exit"
    echo "=========================================="
    echo "Esc — exit | Esc in submenu — back to menu"
    echo -n "Select an option [1-8]: "
}

MENU_ESC=0

consume_escape_suffix() {
    local rest=""
    read -rsn1 -t 0.01 rest < /dev/tty 2>/dev/null || return 0
    if [[ "$rest" == '[' ]]; then
        read -rsn1 -t 0.01 rest < /dev/tty 2>/dev/null || true
    fi
}

# Read a line from /dev/tty; Esc returns 1
_read_line_with_esc() {
    local prompt="$1"
    local varname="$2"
    local input="" c

    if [[ -n "$prompt" ]]; then
        echo -ne "$prompt" > /dev/tty
    fi

    while true; do
        if ! IFS= read -rsn1 c < /dev/tty; then
            return 1
        fi
        if [[ "$c" == $'\e' ]]; then
            consume_escape_suffix
            echo "" > /dev/tty
            printf -v "$varname" ''
            return 1
        elif [[ -z "$c" ]]; then
            break
        elif [[ "$c" == $'\177' ]] || [[ "$c" == $'\b' ]]; then
            if [[ -n "$input" ]]; then
                input="${input%?}"
                printf '\b \b' > /dev/tty
            fi
        else
            input+="$c"
            printf '%s' "$c" > /dev/tty
        fi
    done

    echo "" > /dev/tty
    printf -v "$varname" '%s' "$input"
    return 0
}

# Function to read from terminal (Esc in submenu → back to menu)
read_from_terminal() {
    local prompt="" varname="REPLY"
    local args=("$@")
    local i=0

    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            -p)
                prompt="${args[$((i + 1))]}"
                i=$((i + 2))
                ;;
            *)
                varname="${args[$i]}"
                i=$((i + 1))
                ;;
        esac
    done

    if ! _read_line_with_esc "$prompt" "$varname"; then
        MENU_ESC=1
        echo -e "\n${YELLOW}Esc — back to menu${NC}"
        return 1
    fi
    return 0
}

# Menu choice read (Esc → exit script)
read_menu_choice() {
    local choice=""
    if ! _read_line_with_esc "" choice; then
        return 1
    fi
    REPLY="$choice"
    return 0
}

pause_before_menu() {
    if [[ "$MENU_ESC" == "1" ]]; then
        return
    fi
    echo ""
    if ! _read_line_with_esc "Press Enter to continue (Esc — menu): " _; then
        MENU_ESC=1
    fi
}

# Generate random port between 10000-65000
generate_random_port() {
    echo $(shuf -i 10000-65000 -n 1)
}

SQUID_PROXY_PORT=3128
SQUID_PASSWD_FILE="/etc/squid/passwd"
SQUID_MARKER="/etc/squid/.spielerx-proxy-configured"

get_script_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

get_server_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}

# Generate secure password (12-16 alphanumeric + symbols)
generate_secure_password() {
    local length=$((12 + RANDOM % 5))
    local password=""
    while [[ ${#password} -lt $length ]]; do
        password+=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9!@#$%&*+-=' | head -c $((length - ${#password})))
    done
    echo "${password:0:$length}"
}

find_basic_ncsa_auth() {
    local p
    for p in /usr/lib/squid/basic_ncsa_auth /usr/lib64/squid/basic_ncsa_auth /usr/lib/squid3/basic_ncsa_auth; do
        if [[ -x "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

setup_squid_proxy() {
    echo -e "\n${YELLOW}=== Squid Proxy Setup ===${NC}"
    echo "HTTP proxy with basic authentication (port ${SQUID_PROXY_PORT})."
    echo ""

    local script_dir squid_clients_dir client_file login password server_ip basic_auth_prog

    script_dir=$(get_script_dir)
    squid_clients_dir="${script_dir}/squid-clients"
    mkdir -p "$squid_clients_dir"

    read_from_terminal -p "Enter proxy login: " login || return

    if [[ -z "$login" ]]; then
        echo -e "${RED}Login cannot be empty.${NC}"
        return
    fi

    if [[ ! "$login" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{2,31}$ ]]; then
        echo -e "${RED}Invalid login. Use 3-32 characters: letters, digits, underscore, hyphen.${NC}"
        return
    fi

    client_file="${squid_clients_dir}/${login}.txt"

    if [[ -f "$client_file" ]]; then
        echo -e "${RED}Error: client file already exists:${NC} ${client_file}"
        echo -e "${YELLOW}Choose a different login to generate a new proxy configuration.${NC}"
        return
    fi

    password=$(generate_secure_password)
    server_ip=$(get_server_ip)

    if [[ -z "$server_ip" ]]; then
        echo -e "${RED}Could not detect server IP address.${NC}"
        return
    fi

    echo ""
    echo "Installing Squid and dependencies..."
    apt-get update -qq
    apt-get install -y -qq squid apache2-utils openssl

    basic_auth_prog=$(find_basic_ncsa_auth)
    if [[ -z "$basic_auth_prog" ]]; then
        echo -e "${RED}basic_ncsa_auth not found. Squid auth helper is missing.${NC}"
        return
    fi

    if [[ ! -f "$SQUID_MARKER" ]]; then
        echo "Configuring Squid..."

        cp /etc/squid/squid.conf "/etc/squid/squid.conf.backup.$(date +%Y%m%d_%H%M%S)"

        touch "$SQUID_PASSWD_FILE"
        chmod 640 "$SQUID_PASSWD_FILE"
        chown root:proxy "$SQUID_PASSWD_FILE" 2>/dev/null || chown root:root "$SQUID_PASSWD_FILE"

        mkdir -p /etc/squid/conf.d

        # Disable default http_access rules so only authenticated clients are allowed
        sed -i 's/^http_access/#http_access/' /etc/squid/squid.conf

        cat > /etc/squid/conf.d/spielerx-proxy.conf << EOF
# SpielerX HTTP proxy (basic auth)
auth_param basic program ${basic_auth_prog} ${SQUID_PASSWD_FILE}
auth_param basic children 5 startup=5 idle=1
auth_param basic realm Squid Proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
http_access deny all
EOF

        if grep -q '^http_port ' /etc/squid/squid.conf 2>/dev/null; then
            sed -i "s/^http_port .*/http_port ${SQUID_PROXY_PORT}/" /etc/squid/squid.conf
        else
            echo "http_port ${SQUID_PROXY_PORT}" >> /etc/squid/squid.conf
        fi

        if ! grep -q '^include /etc/squid/conf.d/\*.conf' /etc/squid/squid.conf 2>/dev/null; then
            echo 'include /etc/squid/conf.d/*.conf' >> /etc/squid/squid.conf
        fi

        touch "$SQUID_MARKER"
    fi

    if ! htpasswd -b "$SQUID_PASSWD_FILE" "$login" "$password" 2>/dev/null; then
        echo -e "${RED}Failed to add proxy user (login may already exist in Squid).${NC}"
        echo -e "${YELLOW}Try a different login.${NC}"
        return
    fi

    chmod 640 "$SQUID_PASSWD_FILE"
    chown root:proxy "$SQUID_PASSWD_FILE" 2>/dev/null || chown root:root "$SQUID_PASSWD_FILE"

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow ${SQUID_PROXY_PORT}/tcp comment 'Squid HTTP proxy' >/dev/null 2>&1
    fi

    if ! squid -k parse 2>/dev/null; then
        echo -e "${RED}Squid configuration test failed. Check: squid -k parse${NC}"
        return
    fi

    systemctl enable squid >/dev/null 2>&1
    systemctl restart squid

    if ! systemctl is-active --quiet squid; then
        echo -e "${RED}Squid failed to start. Check: journalctl -u squid -n 50${NC}"
        return
    fi

    cat > "$client_file" << EOF
Squid Proxy Client (created $(date))
========================================
IP:       ${server_ip}
Port:     ${SQUID_PROXY_PORT}
Login:    ${login}
Password: ${password}

Proxy URL:
http://${login}:${password}@${server_ip}:${SQUID_PROXY_PORT}
EOF
    chmod 600 "$client_file"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        SQUID PROXY READY                 ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BLUE}IP:${NC}       ${GREEN}${server_ip}${NC}"
    echo -e "  ${BLUE}Port:${NC}     ${GREEN}${SQUID_PROXY_PORT}${NC}"
    echo -e "  ${BLUE}Login:${NC}    ${GREEN}${login}${NC}"
    echo -e "  ${BLUE}Password:${NC} ${GREEN}${password}${NC}"
    echo ""
    echo -e "  ${YELLOW}http://${login}:${password}@${server_ip}:${SQUID_PROXY_PORT}${NC}"
    echo ""
    echo -e "Credentials saved to: ${BLUE}${client_file}${NC}"
}

setup_ssh_key_auth() {
    echo -e "\n${YELLOW}=== SSH Key Authentication Setup ===${NC}"
    echo "This will disable password authentication and enable SSH key only."
    echo ""
    
    read_from_terminal -p "Enter your SSH public key: " ssh_key || return
    
    if [[ -z "$ssh_key" ]]; then
        echo -e "${RED}No SSH key provided. Aborting.${NC}"
        return
    fi
    
    echo -e "\n${YELLOW}Summary:${NC}"
    echo "- Add SSH key to authorized_keys"
    echo "- Disable password authentication"
    echo "- Disable root password login"
    echo ""
    read_from_terminal -p "Confirm? (yes/no): " confirm || return
    
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${RED}Operation cancelled.${NC}"
        return
    fi
    
    # Create .ssh directory if it doesn't exist
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    
    # Add SSH key
    echo "$ssh_key" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    
    # Backup SSH config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
    
    # Disable password authentication
    sed -i 's/#*PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/#*PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/#*PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    
    # Ensure these settings are set
    grep -q "^PasswordAuthentication" /etc/ssh/sshd_config || echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
    grep -q "^PubkeyAuthentication" /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
    
    # Restart SSH service (try both sshd and ssh)
    if systemctl restart sshd 2>/dev/null; then
        echo -e "${GREEN}✓ SSH service restarted (sshd)${NC}"
    elif systemctl restart ssh 2>/dev/null; then
        echo -e "${GREEN}✓ SSH service restarted (ssh)${NC}"
    else
        echo -e "${RED}✗ Failed to restart SSH service${NC}"
        return
    fi
    
    echo -e "${GREEN}✓ SSH key authentication configured successfully!${NC}"
    echo -e "${YELLOW}⚠ IMPORTANT: Test SSH key login in another terminal before closing this session!${NC}"
}

configure_swap() {
    echo -e "\n${YELLOW}=== Swap File Configuration ===${NC}"
    
    # Show current swap
    current_swap=$(free -h | grep Swap | awk '{print $2}')
    echo "Current swap: $current_swap"
    echo ""
    
    read_from_terminal -p "Enter swap size in GB (0 to remove swap): " swap_size || return
    
    if ! [[ "$swap_size" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid input. Please enter a number.${NC}"
        return
    fi
    
    echo -e "\n${YELLOW}Summary:${NC}"
    if [[ "$swap_size" -eq 0 ]]; then
        echo "- Remove existing swap file"
    else
        echo "- Create/Update swap file: ${swap_size}GB"
    fi
    echo ""
    read_from_terminal -p "Confirm? (yes/no): " confirm || return
    
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${RED}Operation cancelled.${NC}"
        return
    fi
    
    # Disable and remove existing swap
    swapoff -a
    rm -f /swapfile
    sed -i '/\/swapfile/d' /etc/fstab
    
    if [[ "$swap_size" -gt 0 ]]; then
        # Create new swap
        echo "Creating ${swap_size}GB swap file..."
        fallocate -l ${swap_size}G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo -e "${GREEN}✓ Swap file created successfully!${NC}"
    else
        echo -e "${GREEN}✓ Swap file removed successfully!${NC}"
    fi
    
    # Show new swap
    free -h | grep Swap
}

setup_vpn() {
    echo -e "\n${YELLOW}=== VPN Setup ===${NC}"
    echo "This will download and run the VPN setup script."
    echo ""
    read_from_terminal -p "Confirm? (yes/no): " confirm || return
    
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${RED}Operation cancelled.${NC}"
        return
    fi
    
    wget https://git.io/vpnsetup -O vpnsetup.sh && sudo sh vpnsetup.sh
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ VPN setup completed!${NC}"
    else
        echo -e "${RED}✗ VPN setup failed!${NC}"
    fi
}

install_docker() {
    echo -e "\n${YELLOW}=== Docker & Docker Compose Installation ===${NC}"
    echo "This will install Docker and Docker Compose."
    echo ""
    read_from_terminal -p "Confirm? (yes/no): " confirm || return
    
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${RED}Operation cancelled.${NC}"
        return
    fi
    
    # Update package index
    apt-get update
    
    # Install prerequisites
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    # Add Docker's official GPG key
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker Engine
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Start and enable Docker
    systemctl start docker
    systemctl enable docker
    
    # Verify installation
    docker --version
    docker compose version
    
    echo -e "${GREEN}✓ Docker and Docker Compose installed successfully!${NC}"
    echo -e "${YELLOW}Note: You may want to add your user to the docker group:${NC}"
    echo "  usermod -aG docker \$USER"
}

install_dokploy() {
    echo -e "\n${YELLOW}=== Dokploy Installation ===${NC}"
    echo "Dokploy is a self-hosted Platform as a Service."
    echo ""
    echo "Requirements:"
    echo "- Ports 80 and 443 must be free"
    echo "- At least 2GB RAM and 30GB disk space"
    echo ""
    echo "Note: Domain configuration is done through the web UI after installation."
    echo ""
    read_from_terminal -p "Confirm installation? (yes/no): " confirm || return
    
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${RED}Operation cancelled.${NC}"
        return
    fi
    
    # Check if ports 80 and 443 are free
    if ss -tulnp | grep ':80 ' >/dev/null; then
        echo -e "${RED}Error: Port 80 is already in use!${NC}"
        echo "Dokploy requires port 80 to be free."
        return
    fi
    
    if ss -tulnp | grep ':443 ' >/dev/null; then
        echo -e "${RED}Error: Port 443 is already in use!${NC}"
        echo "Dokploy requires port 443 to be free."
        return
    fi
    
    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}Docker is not installed. It will be installed automatically by Dokploy.${NC}"
    fi
    
    # Install Dokploy
    echo "Installing Dokploy..."
    curl -sSL https://dokploy.com/install.sh | sh
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ Dokploy installed successfully!${NC}"
        echo ""
        echo -e "${YELLOW}Next steps:${NC}"
        echo "1. Access Dokploy at: http://$(hostname -I | awk '{print $1}'):3000"
        echo "2. Create your admin account"
        echo "3. Configure your domain in the Web Server section (if needed)"
        echo "4. Enable HTTPS with Let's Encrypt (if domain is configured)"
    else
        echo -e "${RED}✗ Dokploy installation failed!${NC}"
        echo "Check the error messages above for details."
    fi
}

security_hardening() {
    echo -e "\n${YELLOW}╔══════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║       SECURITY HARDENING                 ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "This will perform the following actions:"
    echo ""
    echo -e "${BLUE}1. Run Lynis security audit${NC} (optional, for report)"
    echo -e "${BLUE}2. Change SSH port${NC} from 22 to random (10000-65000)"
    echo -e "${BLUE}3. Configure UFW firewall${NC}"
    echo "   - Allow new SSH port"
    echo "   - Allow HTTP (80)"
    echo "   - Allow HTTPS (443)"
    echo "   - Allow Dokploy (3000)"
    echo "   - Deny everything else"
    echo -e "${BLUE}4. Enable automatic security updates${NC}"
    echo -e "${BLUE}5. Apply kernel security settings${NC} (sysctl)"
    echo -e "${BLUE}6. Install fail2ban${NC} (optional)"
    echo ""
    
    # Check current SSH port
    current_ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    if [[ -z "$current_ssh_port" ]]; then
        current_ssh_port=22
    fi
    echo -e "Current SSH port: ${YELLOW}${current_ssh_port}${NC}"
    echo ""
    
    read_from_terminal -p "Continue with security hardening? (yes/no): " confirm || return
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${RED}Operation cancelled.${NC}"
        return
    fi
    
    # Ask about Lynis
    echo ""
    read_from_terminal -p "Run Lynis audit first? (yes/no): " run_lynis || return
    
    # Ask about fail2ban
    read_from_terminal -p "Install fail2ban? (recommended: no if using SSH keys) (yes/no): " install_fail2ban || return
    
    # Ask about custom ports
    echo ""
    echo -e "${YELLOW}Port configuration:${NC}"
    new_ssh_port=$(generate_random_port)
    echo "Generated random SSH port: $new_ssh_port"
    read_from_terminal -p "Use this port or enter custom (press Enter for $new_ssh_port): " custom_port || return
    if [[ -n "$custom_port" ]] && [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        new_ssh_port=$custom_port
    fi
    
    # Additional ports
    read_from_terminal -p "Additional ports to open (comma-separated, e.g., 8080,9000) or Enter to skip: " extra_ports || return
    
    echo ""
    echo -e "${YELLOW}══════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Summary of changes:${NC}"
    echo -e "  SSH port: ${current_ssh_port} → ${GREEN}${new_ssh_port}${NC}"
    echo -e "  UFW ports: ${GREEN}${new_ssh_port}/tcp, 80/tcp, 443/tcp, 3000/tcp${NC}"
    if [[ -n "$extra_ports" ]]; then
        echo -e "  Extra ports: ${GREEN}${extra_ports}${NC}"
    fi
    echo -e "  Lynis audit: ${run_lynis}"
    echo -e "  Fail2ban: ${install_fail2ban}"
    echo -e "  Auto security updates: ${GREEN}yes${NC}"
    echo -e "  Kernel hardening: ${GREEN}yes${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════${NC}"
    echo ""
    echo -e "${RED}⚠ WARNING: Make sure you can access the server on the new SSH port!${NC}"
    echo -e "${RED}⚠ Keep this session open until you verify new port works!${NC}"
    echo ""
    read_from_terminal -p "Apply all changes? (yes/no): " final_confirm || return
    
    if [[ "$final_confirm" != "yes" ]]; then
        echo -e "${RED}Operation cancelled.${NC}"
        return
    fi
    
    echo ""
    echo -e "${BLUE}Starting security hardening...${NC}"
    echo ""
    
    # ==========================================
    # 1. LYNIS AUDIT (optional)
    # ==========================================
    if [[ "$run_lynis" == "yes" ]]; then
        echo -e "${YELLOW}[1/6] Running Lynis audit...${NC}"
        if ! command -v lynis &> /dev/null; then
            apt-get update -qq
            apt-get install -y -qq lynis
        fi
        lynis audit system --quick 2>/dev/null | tail -50
        echo -e "${GREEN}✓ Lynis audit complete${NC}"
        echo "  Full report: /var/log/lynis-report.dat"
        echo ""
    else
        echo -e "${YELLOW}[1/6] Lynis audit skipped${NC}"
    fi
    
    # ==========================================
    # 2. CHANGE SSH PORT
    # ==========================================
    echo -e "${YELLOW}[2/6] Changing SSH port to ${new_ssh_port}...${NC}"
    
    # Backup SSH config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
    
    # Remove existing Port lines and add new one
    sed -i '/^#*Port /d' /etc/ssh/sshd_config
    echo "Port ${new_ssh_port}" >> /etc/ssh/sshd_config
    
    # Additional SSH hardening
    sed -i 's/#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
    sed -i 's/#*LoginGraceTime.*/LoginGraceTime 30/' /etc/ssh/sshd_config
    sed -i 's/#*X11Forwarding yes/X11Forwarding no/' /etc/ssh/sshd_config
    
    # Add if not exists
    grep -q "^MaxAuthTries" /etc/ssh/sshd_config || echo "MaxAuthTries 3" >> /etc/ssh/sshd_config
    grep -q "^LoginGraceTime" /etc/ssh/sshd_config || echo "LoginGraceTime 30" >> /etc/ssh/sshd_config
    
    echo -e "${GREEN}✓ SSH port changed to ${new_ssh_port}${NC}"
    
    # ==========================================
    # 3. CONFIGURE UFW FIREWALL
    # ==========================================
    echo -e "${YELLOW}[3/6] Configuring UFW firewall...${NC}"
    
    # Install UFW if needed
    if ! command -v ufw &> /dev/null; then
        apt-get install -y -qq ufw
    fi
    
    # Reset UFW to defaults
    ufw --force reset >/dev/null
    
    # Set default policies
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    
    # Allow required ports
    ufw allow ${new_ssh_port}/tcp comment 'SSH' >/dev/null
    ufw allow 80/tcp comment 'HTTP' >/dev/null
    ufw allow 443/tcp comment 'HTTPS' >/dev/null
    ufw allow 3000/tcp comment 'Dokploy' >/dev/null
    
    # Allow extra ports if specified
    if [[ -n "$extra_ports" ]]; then
        IFS=',' read -ra PORTS <<< "$extra_ports"
        for port in "${PORTS[@]}"; do
            port=$(echo "$port" | tr -d ' ')
            if [[ "$port" =~ ^[0-9]+$ ]]; then
                ufw allow ${port}/tcp comment 'Custom' >/dev/null
                echo "  Added port ${port}/tcp"
            fi
        done
    fi
    
    # Enable UFW
    ufw --force enable >/dev/null
    
    echo -e "${GREEN}✓ UFW firewall configured and enabled${NC}"
    ufw status numbered
    echo ""
    
    # ==========================================
    # 4. AUTOMATIC SECURITY UPDATES
    # ==========================================
    echo -e "${YELLOW}[4/6] Enabling automatic security updates...${NC}"
    
    apt-get install -y -qq unattended-upgrades apt-listchanges
    
    # Configure unattended-upgrades
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    
    # Enable security updates only
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    
    systemctl enable unattended-upgrades >/dev/null 2>&1
    systemctl start unattended-upgrades >/dev/null 2>&1
    
    echo -e "${GREEN}✓ Automatic security updates enabled${NC}"
    
    # ==========================================
    # 5. KERNEL SECURITY (SYSCTL)
    # ==========================================
    echo -e "${YELLOW}[5/6] Applying kernel security settings...${NC}"
    
    cat > /etc/sysctl.d/99-security.conf << 'EOF'
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Block SYN attacks
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Log Martians
net.ipv4.conf.all.log_martians = 1

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Disable IPv6 if not needed (uncomment if you don't use IPv6)
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
EOF
    
    sysctl -p /etc/sysctl.d/99-security.conf >/dev/null 2>&1
    
    echo -e "${GREEN}✓ Kernel security settings applied${NC}"
    
    # ==========================================
    # 6. FAIL2BAN (optional)
    # ==========================================
    if [[ "$install_fail2ban" == "yes" ]]; then
        echo -e "${YELLOW}[6/6] Installing fail2ban...${NC}"
        
        apt-get install -y -qq fail2ban
        
        # Configure fail2ban for SSH
        cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ${new_ssh_port}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 24h
EOF
        
        systemctl enable fail2ban >/dev/null 2>&1
        systemctl restart fail2ban >/dev/null 2>&1
        
        echo -e "${GREEN}✓ Fail2ban installed and configured${NC}"
    else
        echo -e "${YELLOW}[6/6] Fail2ban skipped${NC}"
    fi
    
    # ==========================================
    # RESTART SSH
    # ==========================================
    echo ""
    echo -e "${YELLOW}Restarting SSH service...${NC}"
    
    if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
        echo -e "${GREEN}✓ SSH service restarted${NC}"
    else
        echo -e "${RED}✗ Failed to restart SSH - CHECK MANUALLY!${NC}"
    fi
    
    # ==========================================
    # FINAL SUMMARY
    # ==========================================
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     SECURITY HARDENING COMPLETE!         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT - New connection command:${NC}"
    echo ""
    echo -e "  ${GREEN}ssh -p ${new_ssh_port} root@$(hostname -I | awk '{print $1}')${NC}"
    echo ""
    echo -e "${RED}⚠ TEST THIS IN A NEW TERMINAL BEFORE CLOSING THIS SESSION!${NC}"
    echo ""
    echo "Open ports:"
    ufw status | grep -E "^\[|ALLOW"
    echo ""
    echo -e "Lynis report: ${BLUE}/var/log/lynis-report.dat${NC}"
    echo -e "SSH config backup: ${BLUE}/etc/ssh/sshd_config.backup.*${NC}"
    echo ""
    
    # Save connection info to file
    cat > /root/ssh-connection-info.txt << EOF
SSH Connection Info (generated $(date))
========================================
Port: ${new_ssh_port}
IP: $(hostname -I | awk '{print $1}')

Connection command:
ssh -p ${new_ssh_port} root@$(hostname -I | awk '{print $1}')

Open firewall ports:
$(ufw status | grep ALLOW)
EOF
    
    echo -e "Connection info saved to: ${BLUE}/root/ssh-connection-info.txt${NC}"
}

# Main loop
while true; do
    show_menu
    MENU_ESC=0

    if ! read_menu_choice; then
        echo -e "\n${GREEN}Goodbye!${NC}"
        exit 0
    fi
    choice="$REPLY"

    case $choice in
        1)
            setup_ssh_key_auth
            pause_before_menu
            ;;
        2)
            configure_swap
            pause_before_menu
            ;;
        3)
            setup_vpn
            pause_before_menu
            ;;
        4)
            install_docker
            pause_before_menu
            ;;
        5)
            install_dokploy
            pause_before_menu
            ;;
        6)
            security_hardening
            pause_before_menu
            ;;
        7)
            setup_squid_proxy
            pause_before_menu
            ;;
        8)
            echo -e "\n${GREEN}Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            pause_before_menu
            ;;
    esac
done
