# Day-0 Discovery Questionnaire

Run in stakeholder workshops; answers feed the HLD and risk register.
Blank fields = open questions = risks.

## Business context
- What business outcome does this platform serve? Deadline driver?
- Cost of one hour of downtime? Of a failed launch?
- Compliance/regulatory regime (PCI, HIPAA, internal)?
- Who signs off on go-live? Who operates after?

## Workloads
- Application inventory: count, type (web/API/batch/stateful), language/runtime
- Stateful components: databases, queues, files — in-cluster or external?
- Sizing: requests/limits today, peak concurrency, growth rate
- Burst/seasonal patterns?

## Infrastructure
- Compute substrate: cloud / bare metal / virtualization (which hypervisor?)
- Network: subnets, VLANs, load balancers (F5/AVI/HAProxy?), DNS ownership
- Storage: existing arrays/NFS/object; required IOPS/latency
- Outbound: proxy required? Air-gapped? Egress firewall rules?

## Identity & security
- Corporate IdP: AD/LDAP/Kerberos/OIDC? Group model?
- PKI: internal CA available? Cert issuance process?
- Secret management: Vault/external store or in-cluster?
- Security baseline: FIPS, SCC policies, image scanning, registry policy?

## Operations
- Team skills: who runs k8s today? Linux/network depth?
- Existing tooling: monitoring, logging, ticketing, CI/CD?
- Change windows & freeze periods?
- On-call model?

## Non-functional requirements
- Availability target: ___%  | RTO: ___ | RPO: ___
- Performance: latency budget ___ms, throughput ___
- Scale: nodes ___, namespaces ___, tenants ___
- DR: single site / multi-site? Existing DR tooling?

## Constraints & dependencies
- Fixed constraints (licensing, hardware lead time, contracts)
- Other teams' deliverables this depends on (DNS, VIPs, FW rules, certs)
- Known risks the customer already suspects
