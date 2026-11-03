# ADR 0003: 3-Node Full-Mesh Direct Cluster Fabric with FRR OSPF

## Status
Accepted

## Context
Ceph replication and Corosync ring 1 require high bandwidth and low latency across the 3 nodes. Incorporating an external 10G/2.5G switch adds cost and point-of-failure complexity. With 3 nodes and 2 cluster NICs per node (USB 2.5G and WiFi-slot M.2 2.5G), 3 direct Ethernet cables form a complete triangle mesh.

## Decision
Connect the nodes directly in a full mesh (pve01↔pve02, pve01↔pve03, pve02↔pve03) over three /30 subnets (10.10.12.0/30, 10.10.13.0/30, 10.10.23.0/30). Run OSPF via FRRouting (`frr`) to make the direct links mutually routable and resilient to single-link failures.

## Consequences
- No external switch required for high-speed cluster storage fabric.
- FRR is required and must not be stopped when SDN is disabled.
- Static host routes on physical interfaces are omitted; OSPF dynamically establishes routing.
