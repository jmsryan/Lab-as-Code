# Hypervisor Bootstrap Procedure

## Purpose

This document describes the **manual bootstrap steps** required to prepare a
bare-metal system for Ansible-based configuration.

These steps are intentionally limited in scope and are performed **once per
host**. After completion, all ongoing configuration and state enforcement is
handled by automation.

This document exists to:
- make the build process reproducible
- clearly define where automation begins
- prevent undocumented “magic” steps

---

## Scope and Intent

This procedure:
- applies only to initial host provisioning
- is expected to be executed manually
- results in a system ready for Ansible control

Once these steps are complete, no further manual configuration of the host
should be required.

---

## Prerequisites

- Physical access to the host
- A workstation capable of writing USB media
- Network connectivity providing DHCP on the infrastructure network
- SSH keypair for the automation user

---

## Bootstrap Workflow Overview

At a high level, the bootstrap process consists of:

1. Preparing OS installation media
2. Preparing cloud-init bootstrap media
3. Installing the base operating system
4. Installing and executing cloud-init
5. Verifying Ansible readiness

Each step is described below.

---

## Step-by-Step Procedure

### 1. Prepare Debian Installation Media

- Download the appropriate Debian ISO image
- Write the ISO to a USB drive using a raw disk copy tool

Notes:
- A direct disk copy method is used to avoid tooling-specific behavior
- Progress reporting and write synchronization are enabled to ensure integrity

This USB drive is used only to install the base operating system.

---

### 2. Prepare cloud-init Bootstrap Media

- Format a second USB drive with a FAT filesystem
- Label the filesystem `CIDATA`
- Copy the following files to the root of the filesystem:
  - `user-data`
  - `meta-data`

These files define the **temporary bootstrap configuration** used by cloud-init.

This media provides:
- initial access configuration
- temporary identity
- prerequisites for Ansible connectivity

---

### 3. Install the Base Operating System

- Boot the system from the Debian installation USB
- Install a minimal Debian system
- Set a **temporary root password** for use during installation only
- Configure networking using DHCP

No additional software or configuration is performed during this step.

---

### 4. Install cloud-init

After the OS installation completes:

- Log in locally using the temporary root credentials
- Install the `cloud-init` package
- Ensure cloud-init is enabled to run on next boot

This step prepares the system to consume the bootstrap configuration provided
by the `CIDATA` media.

---

### 5. Reboot and Execute cloud-init

- Reboot the system with the `CIDATA` USB inserted
- cloud-init executes automatically during boot
- Temporary bootstrap configuration is applied

At the conclusion of this step, the system should be reachable via SSH using
the automation user and SSH key defined in `user-data`.

---

### 6. Verify Ansible Readiness

From a separate machine:

- Identify the system’s IP address via DHCP lease information
- Establish an SSH connection using:
  - the automation user
  - the corresponding private SSH key

Successful SSH access confirms:
- cloud-init executed correctly
- access prerequisites are in place
- the host is ready for Ansible configuration

---

## Post-Bootstrap State

After successful completion of this procedure:

- The host has a temporary bootstrap identity
- cloud-init has completed its role
- Ansible is expected to take full ownership of configuration and identity
- No further manual changes should be made to the host

Any subsequent configuration must be performed via automation.

---

## Relationship to Automation

This bootstrap procedure intentionally ends **exactly where Ansible begins**.

- cloud-init state is considered disposable
- Ansible is authoritative for all long-lived configuration
- Rebuilds follow this same procedure from the beginning

This clear handoff enforces reproducibility and prevents configuration drift.

---

## Summary

This document captures the **minimum required manual steps** to bring a
bare-metal system into an automation-ready state.

By explicitly documenting these steps, the platform avoids hidden assumptions
and ensures that future rebuilds remain predictable and repeatable.