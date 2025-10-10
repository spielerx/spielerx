#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

show_menu() {
    clear
    echo "=========================================="
    echo "    Ubuntu Server Setup Tool"
    echo "=========================================="
    echo "1) Setup SSH Key Authentication Only"
    echo "2) Configure Swap File"
    echo "3) Setup VPN Connection"
    echo "4) Install Docker & Docker Compose"
    echo "5) Install Dokploy"
    echo "6) Exit"
    echo "=========================================="
    echo -n "Select an option [1-6]: "
}

setup_ssh_key_auth() {
    echo -e "\n${YELLOW}=== SSH Key Authentication Setup ===${NC}"
    echo "This will disable password authentication and enable SSH key only."
    echo ""
    
    read -p "Enter your SSH public key: " ssh_key
    
    if [[ -z "$ssh_key" ]]; then
        echo -e "${RED}No SSH key provided. Aborting.${NC}"
        return
    fi
    
    echo -e "\n${YELLOW}Summary:${NC}"
    echo "- Add SSH key to authorized_keys"
    echo "- Disable password authentication"
    echo "- Disable root password login"
    echo ""
    read -p "Confirm? (yes/no): " confirm
    
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
    
    # Restart SSH service
    systemctl restart sshd
    
    echo -e "${GREEN}✓ SSH key authentication configured successfully!${NC}"
    echo -e "${YELLOW}⚠ IMPORTANT: Test SSH key login in another terminal before closing this session!${NC}"
}

configure_swap() {
    echo -e "\n${YELLOW}=== Swap File Configuration ===${NC}"
    
    # Show current swap
    current_swap=$(free -h | grep Swap | awk '{print $2}')
    echo "Current swap: $current_swap"
    echo ""
    
    read -p "Enter swap size in GB (0 to remove swap): " swap_size
    
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
    read -p "Confirm? (yes/no): " confirm
    
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
    read -p "Confirm? (yes/no): " confirm
    
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
    read -p "Confirm? (yes/no): " confirm
    
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
    read -p "Confirm installation? (yes/no): " confirm
    
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

# Main loop
while true; do
    show_menu
    read choice
    
    case $choice in
        1)
            setup_ssh_key_auth
            read -p "Press Enter to continue..."
            ;;
        2)
            configure_swap
            read -p "Press Enter to continue..."
            ;;
        3)
            setup_vpn
            read -p "Press Enter to continue..."
            ;;
        4)
            install_docker
            read -p "Press Enter to continue..."
            ;;
        5)
            install_dokploy
            read -p "Press Enter to continue..."
            ;;
        6)
            echo -e "\n${GREEN}Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            read -p "Press Enter to continue..."
            ;;
    esac
done
