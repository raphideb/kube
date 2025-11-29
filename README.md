# Kubernetes Setup Scripts

This repository contains scripts to set up a vanilla Kubernetes cluster with various database operators and monitoring tools. 

## Directory Structure

This repository is organized into two directories based on your target platform:

### 📁 `wsl/` - For WSL (Windows Subsystem for Linux) with Debian

Use the scripts in the **wsl** directory if you are running **WSL with Debian** on Windows.

These scripts include WSL-specific configurations such as:
- Systemd configuration for WSL
- WSL-specific startup procedures
- Path adjustments for WSL environment

**[📖 Go to WSL documentation →](wsl/README.md)**

### 📁 `debian/` - For Native Debian Installation

Use the scripts in the **debian** directory if you are running **native Debian** directly on Linux (not WSL).

These scripts are optimized for standard Debian installations without WSL-specific code.

**[📖 Go to Debian documentation →](debian/README.md)**

Both variants were tested with Debian 13.

## What Gets Installed

Both directories contain scripts to install:

**Core Infrastructure:**
- Docker with cri-dockerd
- Kubernetes cluster with Calico networking
- Local-path-provisioner for persistent storage
- Helm package manager

**Database Operators:**
- CloudNativePG (PostgreSQL) operator
- MongoDB Community operator
- Oracle Database operator

**Monitoring & Search:**
- Prometheus
- Grafana
- OpenSearch

## Quick Start

1. **Choose your directory** based on your platform (wsl or debian)
2. **Navigate to that directory:**
   ```bash
   cd wsl/    # For WSL users
   # OR
   cd debian/ # For native Debian users
   ```
3. **Follow the README.md** in that directory for installation instructions

## System Requirements

- Debian
- At least 16GB RAM (recommended when running all components)
- Swap will be disabled on WSL; swap can remain enabled on native Debian
- Sudo privileges

## Support

For platform-specific instructions and troubleshooting, refer to the README.md file in the appropriate directory:
- [WSL Installation Guide](wsl/README.md)
- [Debian Installation Guide](debian/README.md)

## Repository Contents

Each directory contains:
- **Installation scripts** (`create_*.sh`) for modular or all-in-one setup
- **Deployment scripts** for additional database instances
- **YAML templates** for cluster configurations
- **Helper scripts** for port forwarding and management
- **Complete documentation** specific to the platform
