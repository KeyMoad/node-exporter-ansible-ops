# node-exporter-ansible-ops

[![Ansible Role](https://img.shields.io/badge/Ansible-Role-blue.svg)](https://galaxy.ansible.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**Ansible role to install, upgrade, and manage Prometheus Node Exporter with systemd, backups, dry-run support, and safe rollback.**

This role is designed for **SREs, DevOps engineers, and monitoring teams** who want a production-ready Node Exporter deployment that’s automated, versioned, and safe.

---

## Features

* Install or update **Node Exporter** on Linux hosts
* Architecture-aware (`amd64`, `arm64`, `armv7`, `ppc64le`)
* Systemd integration with custom unit file
* Automatic backup of existing binary and unit file before upgrades
* Safe rollback if an update fails
* Dry-run mode to preview actions without making changes
* Configurable installation paths, users, and flags
* Easy to use in a role-based structure
* **Bonus:** Standalone Bash script for non-Ansible environments

---

## Requirements

* Ansible ≥ 2.9
* Linux hosts (tested on Ubuntu, CentOS, Debian)
* Network access to the Node Exporter download URL
* `tar` and `curl`/`wget` installed on target hosts

---

## Role Variables

| Variable                          | Default                                                                                      | Description                                     |
| --------------------------------- | -------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| `running_action`                  | `"install"`                                                                                  | Action to perform: `install` or `update`        |
| `dry_run`                         | `false`                                                                                      | Set to true to preview changes without applying |
| `node_exporter_version`           | `"1.8.2"`                                                                                    | Node Exporter version to install/update         |
| `ansible_architecture_map`        | `{ x86_64: amd64, aarch64: arm64, armv7l: armv7, ppc64le: ppc64le }`                         | Architecture mapping                            |
| `node_exporter_arch`              | Calculated from `ansible_architecture_map`                                                   | System architecture for download                |
| `node_exporter_download_base_url` | `https://github.com/prometheus/node_exporter/releases/download/v{{ node_exporter_version }}` | Base URL for Node Exporter releases             |
| `node_exporter_filename`          | `"node_exporter-{{ node_exporter_version }}.linux-{{ node_exporter_arch }}"`                 | Archive filename                                |
| `node_exporter_tgz`               | `"{{ node_exporter_filename }}.tar.gz"`                                                      | Archive name                                    |
| `node_exporter_url`               | `"{{ node_exporter_download_base_url }}/{{ node_exporter_tgz }}"`                            | Download URL                                    |
| `node_exporter_install_dir`       | `"/opt/node_exporter"`                                                                       | Directory to store backups                      |
| `node_exporter_binary_dir`        | `"/usr/local/bin"`                                                                           | Directory for the binary                        |
| `node_exporter_binary_path`       | `"{{ node_exporter_binary_dir }}/node_exporter"`                                             | Full path to binary                             |
| `node_exporter_service_name`      | `"node_exporter"`                                                                            | Systemd service name                            |
| `node_exporter_user`              | `"node_exporter"`                                                                            | User to run the service                         |
| `node_exporter_group`             | `"node_exporter"`                                                                            | Group for the service                           |
| `node_exporter_flags`             | `"--collector.systemd --collector.textfile.directory=/var/log/value_monitor"`                | Node Exporter flags                             |
| `node_exporter_backup_dir`        | `"{{ node_exporter_install_dir }}/backups"`                                                  | Backup directory                                |
| `backup_ts`                       | `"{{ ansible_date_time.epoch }}"`                                                            | Timestamp for backups                           |
| `backup_binary_path`              | `"{{ node_exporter_backup_dir }}/node_exporter-{{ backup_ts }}"`                             | Backup path for binary                          |
| `backup_unit_path`                | `"{{ node_exporter_backup_dir }}/{{ node_exporter_service_name }}.service-{{ backup_ts }}"`  | Backup path for systemd unit                    |

> ⚠️ All variables can be overridden in your playbook or inventory.

---

## Example Inventory

```ini
[monitoring_nodes]
server1 ansible_host=192.168.1.100 ansible_port=22 ansible_user=root
server2 ansible_host=192.168.1.101 ansible_port=22 ansible_user=root
```

---

## Example Playbook

```yaml
- name: Node Exporter ops
  hosts: "{{ HOSTS }}"
  become: true
  gather_facts: true

  roles:
    - role: node_exporter
      vars:
        running_action: "update"
        NODE_EXPORTER_VERSION: "1.9.1"
        DRY_RUN: false
```

---

### Dry-Run Mode

Preview what would happen **without making any changes**:

```bash
ansible-playbook -i inventory.ini playbook.yml \
  -e "HOSTS=monitoring_nodes ACTION=install NODE_EXPORTER_VERSION=1.8.2 DRY_RUN=true"
```

This will show steps like:

* Whether Node Exporter will be installed or updated
* Whether the service will be stopped
* Where backups will be created

---

## Usage Examples

### Install Node Exporter

```bash
ansible-playbook -i inventory.ini playbook.yml \
  -e "HOSTS=monitoring_nodes ACTION=install NODE_EXPORTER_VERSION=1.8.2"
```

### Update Node Exporter

```bash
ansible-playbook -i inventory.ini playbook.yml \
  -e "HOSTS=monitoring_nodes ACTION=update NODE_EXPORTER_VERSION=1.9.0"
```

### With Dry Run

```bash
ansible-playbook -i inventory.ini playbook.yml \
  -e "HOSTS=monitoring_nodes ACTION=update NODE_EXPORTER_VERSION=1.9.0 DRY_RUN=true"
```

---

## Backup & Rollback

* Before updating, the existing binary and systemd unit file are backed up automatically.
* In case of failure, the role will **attempt to rollback** to the last working version.
* Backup files are stored under:

```
/opt/node_exporter/backups/
```

---

## Systemd Service

The service file is deployed from a Jinja2 template and includes:

* Automatic restart on failure
* Customizable user/group
* Network target dependency
* Node Exporter flags configurable via `node_exporter_flags`

---

## 🖥️ Standalone Bash Installer

For environments without Ansible, a **Bash script** (`install_node_exporter.sh`) is included. It provides the same features (install, update, dry-run, rollback).

### Usage

```bash
./install_node_exporter.sh --action install --version 1.9.1 --dry-run false \
  --flags "--collector.systemd --collector.textfile.directory=/var/log/value_monitor"
```

### Options

```
--action install|update     Action to perform (required)
--version X.Y.Z             Node Exporter version (required)
--dry-run true|false        Preview actions without applying
--flags "..."                Extra runtime flags for Node Exporter
--install-dir DIR           Install directory (default: /opt/node_exporter)
--binary-dir DIR            Binary directory (default: /usr/local/bin)
--user USER                 System user (default: node_exporter)
--group GROUP               System group (default: node_exporter)
--service-name NAME         Systemd service name (default: node_exporter)
--backup-dir DIR            Directory for backups (default: /opt/node_exporter/backups)
```

### Examples

Install Node Exporter v1.8.2:

```bash
sudo ./install_node_exporter.sh --action install --version 1.8.2
```

Update Node Exporter to v1.9.1 with custom flags:

```bash
sudo ./install_node_exporter.sh --action update --version 1.9.1 \
  --flags "--collector.systemd --collector.cpu"
```

Dry-run preview:

```bash
sudo ./install_node_exporter.sh --action install --version 1.9.1 --dry-run true
```

Rollback (automatic):

* If an update fails, the script restores the last binary and systemd unit from the backup folder.

---

## Contributing

* Open an issue or pull request for bugs or feature requests.
* Follow standard Ansible style (`snake_case`, idempotency, modular tasks).

---

## License

This project is licensed under the **MIT License** – see the [LICENSE](LICENSE) file.
