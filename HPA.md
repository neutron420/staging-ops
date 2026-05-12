# Advanced Database Scaling Guide: Horizontal Scaling and HPA

This document outlines the architectural transition from Vertical Scaling (Current State) to Horizontal Scaling (Production Goal) for stateful services within the Kubernetes cluster.

---

## 1. PostgreSQL Scaling

### Current State
A single StatefulSet pod with Vertical scaling (CPU/RAM limits).

### Horizontal Transition Path
To enable HPA for PostgreSQL, you must implement a Primary-Replica architecture. This is best achieved using the **CloudNativePG (CNPG)** Operator.

**Step-by-Step Implementation:**
1. **Install CNPG Operator:** Deploy the operator to manage the database lifecycle.
2. **Define a Cluster Resource:** Replace the current `StatefulSet` with a `Cluster` manifest.
3. **Replication:** The operator will maintain one Primary (Read/Write) and multiple Replicas (Read-Only).
4. **HPA Configuration:**
   - Attach an HPA to the Replica deployment.
   - Set metrics to scale the number of Replicas based on CPU or connection count.
5. **Connection Pooling:** Use **PgBouncer** (often included in the operator) to manage the increased number of connections from multiple pods.

---

## 2. Redis Scaling

### Current State
A single Deployment pod acting as a standalone cache.

### Horizontal Transition Path
To scale Redis horizontally, you must move from Standalone mode to **Redis Cluster Mode**.

**Step-by-Step Implementation:**
1. **Operator Selection:** Utilize the **Redis Operator** (by OT-CONTAINER or similar).
2. **Sharding:** Configure the cluster with multiple shards. Each shard handles a portion of the keyspace.
3. **Data Distribution:** Update the application code to use a Redis Cluster-aware client library that can map keys to the correct shard.
4. **HPA Configuration:**
   - Scale the number of shards or replicas within each shard based on memory pressure or command throughput.

---

## 3. Elasticsearch Scaling

### Current State
A single node StatefulSet.

### Horizontal Transition Path
Elasticsearch is natively distributed and is scaled by adding more nodes with specific roles.

**Step-by-Step Implementation:**
1. **Operator Selection:** Install the **Elastic Cloud on Kubernetes (ECK)** Operator.
2. **Node Roles:** Define separate node sets for:
   - **Master Nodes:** For cluster management (low resource requirements).
   - **Data Nodes:** For document storage and search (high resource requirements).
3. **Sharding Strategy:** Increase the number of primary and replica shards for each index to allow data to spread across new nodes.
4. **HPA Configuration:**
   - Target the Data Node set.
   - Scale based on JVM Heap usage or CPU utilization during heavy search indexing.

---

## Summary of Changes Required

| Feature | Change Required | Tool/Operator Recommended |
| :--- | :--- | :--- |
| **Persistence** | Moving from local disks to Distributed Storage (CSI). | Longhorn or OpenEBS |
| **Logic** | App must handle Read/Write splitting. | PgBouncer / Cluster-aware SDKs |
| **Management** | Manual YAML to Operator-managed CRDs. | CloudNativePG / ECK / Redis Operator |
| **Discovery** | Static Service IPs to Headless Services. | Kubernetes Native Discovery |

---

**Document Version: 1.0**
**Topic: Stateful Workload Orchestration**
