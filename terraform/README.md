# Terraform — VM Workload Provisioning (Stub)

This directory is reserved for Terraform configuration to manage VM workloads
on the Proxmox cluster once it is stable.

## When to Activate

Activate this once:
1. `pvecm status` shows all 3 nodes in quorum
2. `ceph -s` shows `HEALTH_OK`
3. You need to provision VMs/containers in a reproducible, version-controlled way

## Planned Resources

- Proxmox VMs (using `bpg/proxmox` provider)
- SDN VNets (when `pve_sdn_enabled: true`)
- Storage pools (reference the `ceph-vm` pool created by Ansible)

## Provider Reference

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}
```

See `providers.tf.example` for the provider configuration skeleton.
