# ci-platform
Mock artifactory image publishing pipeline

## Overview

This project provides a CI/CD pipeline for publishing container images to a mock artifactory system. It includes scripts for:
- Publishing container images as archives with metadata
- Managing script versions across runners
- Cleaning up old script versions

## Project Structure

```
ci-platform/
├── .gitlab-ci.yml                  # GitLab CI/CD pipeline configuration
├── scripts/
│   ├── publish-image.sh            # Main script for publishing container images
│   └── cleanup-publish-image.sh    # Script cleanup utility
└── README.md                       # This file
```

---

## Scripts

### 1. `scripts/publish-image.sh`
**Purpose**: Publishes container images to a specified directory structure with metadata.

**Features**:
- Creates docker-archive archives of container images
- Generates SHA256 checksums for verification
- Stores metadata in YAML format (image name, version, source, etc.)
- Uses file locking to prevent concurrent publishing
- Supports atomic publication using temporary directories

**Environment Variables**:
- `IMAGE_NAME`: Name of the image to publish (required)
- `IMAGE_VERSION`: Version of the image (required)
- `IMAGE_REFERENCE`: Full reference to the container image (required)
- `PUBLISH_ROOT`: Root directory for published images (required)
- `LOCAL_STAGE_ROOT`: Temporary staging directory (default: `/var/tmp/image-publisher`)
- `LOCK_FILE`: Path to lock file (default: `/var/lock/image-publisher/publish.lock`)

**Usage**:
```bash
export IMAGE_NAME="my-app"
export IMAGE_VERSION="1.0.0"
export IMAGE_REFERENCE="localhost/my-app:1.0.0"
export PUBLISH_ROOT="/mnt/image-factory/images"

./scripts/publish-image.sh
```

**Requirements**:
- `podman` for container image operations
- `flock` for file locking
- Standard Unix utilities (find, sha256sum, etc.)

---

### 2. `scripts/cleanup-publish-image.sh`
**Purpose**: Cleans up old, untagged versions of scripts from the shared drive.

**Features**:
- Preserves version-tagged directories (e.g., `v1.0.0`, `1.0.0`)
- Removes untagged directories older than 7 days
- Supports dry-run mode for testing
- Logs all actions to `/var/log/scripts-cleanup.log`

**Usage**:
```bash
# Dry run (test without deleting)
./cleanup-publish-image.sh --dry-run

# Actual cleanup
./cleanup-publish-image.sh
```

**Configuration**:
- The script looks for scripts in `/mnt/image-factory/artifactory/ci-platform/scripts/`
- Logs are written to `/var/log/scripts-cleanup.log`

---

## CI/CD Pipeline

The `.gitlab-ci.yml` file defines a pipeline with the following stages:

1. **promote**: Promotes all scripts in the `scripts/` directory to:
   - Shared drive at `/mnt/image-factory/artifactory/$CI_PROJECT_PATH/scripts/`
   - Local runners at `/usr/local/bin/`
   - Scripts are versioned by Git tag or as "latest" for main branch

2. **build**: Builds container images (defined in `templates/pipeline.yml`)

3. **publish**: Publishes container images using the `publish-image.sh` script

**Rules**:
- Script promotion only occurs for commits to the default branch or for tagged commits
- All scripts in the `scripts/` directory are promoted together

---

## Setup Instructions

### 1. Prerequisites

- GitLab Runner with the `container-publish` tag
- Shared storage mounted at `/mnt/image-factory/`
- `podman` installed on all runners
- `flock` installed on all runners (typically part of `util-linux` package)

### 2. Directory Setup

```bash
# Create shared directories
sudo mkdir -p /mnt/image-factory/artifactory/ci-platform/scripts
sudo mkdir -p /var/log
sudo touch /var/log/scripts-cleanup.log
sudo chmod 666 /var/log/scripts-cleanup.log

# Create local script directory
sudo mkdir -p /usr/local/bin
```

### 3. Install the Cleanup Script

```bash
# Copy the cleanup script to the system
sudo cp cleanup-publish-image.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/cleanup-publish-image.sh
```

### 4. Set Up the Cron Job

Edit the root cron table:

```bash
sudo crontab -e
```

Add the following line to run the cleanup daily at 3 AM:

```bash
0 3 * * * /usr/local/bin/cleanup-publish-image.sh >> /var/log/scripts-cleanup.log 2>&1
```

**Notes**:
- Running as root ensures proper permissions for cleanup
- Both stdout and stderr are redirected to the log file
- Adjust the schedule as needed

### 5. Verify the Setup

Test the cleanup script manually:

```bash
# Dry run test
sudo /usr/local/bin/cleanup-publish-image.sh --dry-run

# Check logs
tail -f /var/log/scripts-cleanup.log
```

---

## Versioning

Scripts are versioned using Git tags:
- Tagged commits (e.g., `v1.0.0`) create versioned directories in the shared storage
- Commits to the default branch update the "latest" version
- The cron job preserves all tagged versions and removes untagged versions after 7 days

**Example**:
```bash
# Create a tagged release
git tag v1.0.0
git push --tags
```

This will create a directory `/mnt/image-factory/artifactory/ci-platform/scripts/v1.0.0/` containing all scripts from that tag.

---

## Best Practices

1. **Testing Changes**:
   - Always test changes to `publish-image.sh` on a feature branch first
   - Use the `--dry-run` option when testing the cleanup script

2. **Tagging**:
   - Tag releases with semantic versioning (e.g., `v1.0.0`, `v1.1.0`)
   - Avoid overwriting existing tagged versions

3. **Monitoring**:
   - Regularly check `/var/log/scripts-cleanup.log` for errors
   - Monitor disk usage on the shared storage

4. **Permissions**:
   - Ensure the GitLab Runner has permissions to read/write to the shared storage
   - The cleanup cron job should run as root

---

## Troubleshooting

### Common Issues

1. **Permission Errors**:
   - Ensure the GitLab Runner has proper permissions for `/mnt/image-factory/`
   - The cleanup script needs root permissions to remove directories

2. **Cleanup Not Running**:
   - Verify the cron job is set up: `sudo crontab -l`
   - Check cron service status: `systemctl status cron`
   - Test the script manually

3. **Script Not Updated on Runners**:
   - Verify the promotion job ran successfully in GitLab CI
   - Check that the runner has the `container-publish` tag

4. **Publish Failures**:
   - Ensure `podman` is installed and working
   - Verify the `PUBLISH_ROOT` directory exists and is writable
   - Check lock file permissions

### Debugging

```bash
# Check shared storage contents
ls -la /mnt/image-factory/artifactory/ci-platform/scripts/

# Check local scripts
ls -la /usr/local/bin/

# View cleanup logs
tail -n 50 /var/log/scripts-cleanup.log

# Test the publish script
bash -n scripts/publish-image.sh  # Syntax check
```

---
## Editing This README

When you're ready to make this README your own, just edit this file and use the following template:

```markdown
# Project Name

## Description

## Features

## Usage

## Setup

## Contributing