# cloudera-runtime-install

Deploys the CDP Runtime cluster and Cloudera Flow Management (CFM) services on top of a fully configured Cloudera Manager environment prepared by the **cloudera-install-nonfips** base kit.

---

## Overview

This repository picks up exactly where **cloudera-install-nonfips** (`RUN_MANAGER` + `RUN_AGENT`) leaves off.  It assumes:

- RHEL 9.x hosts
- CM 7.13.2 running and reachable at `http://<MANAGER_HOST>:7180`
- CDP 7.3.2 parcel repo accessible at `https://archive.cloudera.com/p/cdh7/7.3.2.0/parcels/`
- CSA 1.17 parcel repo accessible at `https://archive.cloudera.com/p/csa/1.17.0.0/parcels/`
- CM agent registered on every cluster host
- PostgreSQL 14 running on the manager host
- Databases `scm`, `rman`, `nifireg` already created
- CFM 4.12 CSDs (`NIFI-*.jar`, `NIFIREGISTRY-*.jar`) installed in `/opt/cloudera/csd/`

What this kit adds:

| Step | Script | What it does |
|------|--------|--------------|
| 0 | `00_create_service_databases.sh` | Creates `hue`, `metastore`, `ssb`, and (optionally) `ranger` PostgreSQL databases |
| 1 | `01_install_jdbc_driver.sh` | Installs `postgresql-jdbc` for NiFi Registry and SQL Stream Builder |
| 2 | `02_setup_cms.sh` | Accepts CM trial licence, stores paywall credentials, creates and starts CM Management Services |
| 3 | `03_install_csa_csds.sh` | Downloads Flink and SQL Stream Builder CSD JARs; restarts CM |
| 4 | `04_deploy_cluster.sh` | Imports the cluster template; CM downloads/activates parcels and deploys all services |
| 5 | `05_validate_runtime.sh` | Checks cluster health, port availability, and prints service URLs |

Deployed services:

| Service | Parcel | Purpose |
|---------|--------|---------|
| ZooKeeper | CDP 7.3.2 | Distributed coordination |
| HDFS | CDP 7.3.2 | Distributed file system |
| YARN + Queue Manager | CDP 7.3.2 | Distributed compute |
| Tez | CDP 7.3.2 | YARN execution engine for Hive |
| Hive Metastore | CDP 7.3.2 | Metadata catalog (PostgreSQL-backed) |
| Hive on Tez | CDP 7.3.2 | HiveServer2 SQL interface |
| Hue | CDP 7.3.2 | Web-based data browser (PostgreSQL-backed) |
| NiFi | CFM 4.12 | Data flow (NiFi 2.x, Java 21) |
| NiFi Registry | CFM 4.12 | Flow registry (PostgreSQL-backed) |
| **Flink** | **CSA 1.17** | **Stream processing (Flink 1.20.1)** |
| **SQL Stream Builder** | **CSA 1.17** | **SQL over streaming (PostgreSQL-backed)** |

---

## Prerequisites

1. `cloudera-install-nonfips/RUN_MANAGER` has completed on the manager host.
2. `cloudera-install-nonfips/RUN_AGENT` has completed on each agent host.
3. All hosts appear in CM (`Hosts → All Hosts`).
4. You have your **Cloudera archive credentials** (`CLOUDERA_REPO_USER` / `CLOUDERA_REPO_PASS`).
5. You know the **CDH parcel build string** for the CDP 7.x release you are deploying.

---

## 1. Stage the kit

On the manager host:

```bash
sudo -i
cd /root

git clone <this-repo-url> cloudera-runtime-install
# or copy/unzip the kit
cd cloudera-runtime-install
chmod +x *.sh RUN_RUNTIME
```

---

## 2. Configure EXPORTS

The parcel is pre-configured for **CDP 7.3.2** (build `7.3.2-1.cdh7.3.2.p0.77083870`).

The only values you normally need to review in `EXPORTS` are:

```bash
vi /root/cloudera-runtime-install/EXPORTS
```

```bash
# CM admin password — change if you updated it from the default 'admin'
export CM_ADMIN_PASS='admin'

# CLUSTER_HOST inherits from AGENT_HOST in the base EXPORTS.
# Override here only if CDP services should run on a different host:
# export CLUSTER_HOST='ip-10-0-11-156.us-east-2.compute.internal'

# Java 21 path on CLUSTER_HOST — verify the symlink exists
export NIFI_JAVA_HOME='/usr/lib/jvm/java-21-openjdk'
```

`CLUSTER_HOST` will automatically be the value of `AGENT_HOST` set in the base `cloudera-install-nonfips/EXPORTS`.  You do not need to set it again unless you want to override it.

To confirm the Java 21 path on the agent host:

```bash
ssh <cluster-host> "ls -ld /usr/lib/jvm/java-21-openjdk*"
```

Source EXPORTS before running:

```bash
source /root/cloudera-runtime-install/EXPORTS
```

---

## 3. Install JDBC driver on the agent host

`RUN_RUNTIME` installs `postgresql-jdbc` on the manager host automatically.  If NiFi Registry will run on a **separate agent host**, also install it there:

```bash
ssh <cluster-host> "sudo dnf install -y postgresql-jdbc"
```

Verify the JAR:

```bash
ssh <cluster-host> "ls -lh /usr/share/java/postgresql*.jar"
```

---

## 4. Run the deployment

On the manager host:

```bash
sudo -i
cd /root/cloudera-runtime-install

source ./EXPORTS
sudo -E ./RUN_RUNTIME
```

`RUN_RUNTIME` runs steps 00–04 in order and stops if any step fails.

Step 4 (`04_deploy_cluster.sh`) is the long-running step.  It imports the cluster template into CM, which triggers parcel download, distribution, activation, and service start.  Expect **30–90 minutes** depending on network speed and host resources.

Monitor progress from CM UI:

```
http://<MANAGER_HOST>:7180
```

Or tail the bootstrap log:

```bash
tail -f /var/log/cloudera-bootstrap/04_deploy_cluster_*.log
```

---

## 5. Verify deployment

After `RUN_RUNTIME` completes, run the validation script manually to confirm:

```bash
cd /root/cloudera-runtime-install
source ./EXPORTS
sudo -E bash 05_validate_runtime.sh
```

Expected output includes `[  OK  ]` for all service health checks and port probes.

---

## 6. Service access

| Service | URL |
|---------|-----|
| Cloudera Manager | `http://<MANAGER_HOST>:7180` |
| Hue | `http://<CLUSTER_HOST>:8888` |
| NiFi | `http://<CLUSTER_HOST>:8080/nifi` |
| NiFi Registry | `http://<CLUSTER_HOST>:18080/nifi-registry` |
| HDFS NameNode UI | `http://<CLUSTER_HOST>:9870` |
| YARN ResourceManager UI | `http://<CLUSTER_HOST>:8088` |

Hue default credentials: `admin / admin` (first login creates the admin account).

---

## 7. Database reference

All databases reside on the manager host PostgreSQL 14 instance.

| Service | Database | User | Password | Set by |
|---------|----------|------|----------|--------|
| CM Server | `scm` | `scm` | `ClouderaCM_2026` | base kit |
| Reports Manager | `rman` | `rman` | `Rman_DB_2026` | base kit |
| NiFi Registry | `nifireg` | `nifireg` | `Registry_DB_2026` | base kit |
| Hue | `hue` | `hue` | `Hue_DB_2026` | this kit |
| Hive Metastore | `metastore` | `hive` | `Hive_DB_2026` | this kit |
| SQL Stream Builder | `ssb` | `ssb` | `SSB_DB_2026` | this kit |
| Ranger (optional) | `ranger` | `rangeradmin` | `Ranger_DB_2026` | this kit (`CREATE_EXTRA_DBS=true`) |

All passwords can be changed in EXPORTS before running.

---

## 8. Cluster template

The cluster template is `templates/cluster.json.tmpl`.  Variables use `${VAR}` syntax and are substituted by `04_deploy_cluster.sh` using `envsubst`.

To customise the template before deploying:

- Add or remove services by editing the `services` array.
- Add or remove roles by editing `roleConfigGroupsRefNames` in `hostTemplates` and the corresponding `roleConfigGroups` entries in each service.
- For multi-host clusters, add additional entries to `instantiator.hosts` and `hostTemplates` with appropriate role assignments.

---

## 9. NiFi Registry database configuration

The cluster template sets the NiFi Registry database connection via CM role config properties.  If the import fails with an error about unrecognised config names (the exact names depend on the CFM CSD version), configure the database connection manually in CM after deployment:

1. CM → Clusters → NiFi Registry → Configuration
2. Search for "database"
3. Set:
   - **NiFi Registry JDBC Url**: `jdbc:postgresql://<DB_HOST>:5432/nifireg`
   - **NiFi Registry JDBC Driver**: `org.postgresql.Driver`
   - **NiFi Registry Database Driver Directory**: `/usr/share/java`
   - **NiFi Registry Database Username**: `nifireg`
   - **NiFi Registry Database Password**: `Registry_DB_2026`
4. Save and restart NiFi Registry.

---

## 10. CSA CSD installation (Flink and SQL Stream Builder)

`03_install_csa_csds.sh` downloads the two CSA CSD JARs from the Cloudera archive and places them in `/opt/cloudera/csd/`.  It then restarts the CM server so CM picks up the new service types before the cluster template is imported.

The CSD URLs are derived from `CSA_CSD_BASE_URL` and the jar name variables in `EXPORTS`:

```
https://archive.cloudera.com/p/csa/1.17.0.0/csd/FLINK-1.20.1-csa1.17.0.0-77091851.jar
https://archive.cloudera.com/p/csa/1.17.0.0/csd/SQL_STREAM_BUILDER-1.20.1-csa1.17.0.0-77091851.jar
```

`CLOUDERA_REPO_USER` and `CLOUDERA_REPO_PASS` from the base EXPORTS are used for authentication.

---

## 11. SQL Stream Builder database configuration

The cluster template sets the SSB database connection via CM role config properties on the `STREAMING_SQL_ENGINE` role:

```
ssb.datasource.url      = jdbc:postgresql://<DB_HOST>:<DB_PORT>/ssb
ssb.datasource.username = ssb
ssb.datasource.password = SSB_DB_2026
```

If the import fails due to unrecognised config names, configure the database manually in CM after deployment:

1. CM → Clusters → SQL Stream Builder → Configuration
2. Search for "datasource" or "database"
3. Set the JDBC URL, username, and password
4. Save and restart SQL Stream Builder

SSB web UI: `http://<CLUSTER_HOST>:18121`

---

## 12. NiFi Java 21

NiFi 2.x (CFM 4.x) requires Java 21.  The cluster template sets `nifi.jdk.home` and `nifi.registry.jdk.home` to `${NIFI_JAVA_HOME}`.

If NiFi fails to start with a Java version error, verify the path in EXPORTS:

```bash
ls -ld /usr/lib/jvm/java-21-openjdk*
```

If the generic symlink does not exist, use the full versioned path:

```bash
export NIFI_JAVA_HOME='/usr/lib/jvm/java-21-openjdk-21.0.x.x-x.el9.x86_64'
```

Set the correct path in EXPORTS and re-run `04_deploy_cluster.sh`.  If the cluster already exists, update the NiFi role config directly in CM and restart NiFi.

---

## 13. Re-running after failure

Individual steps are idempotent where possible:

- `00_create_service_databases.sh` — safe to re-run; skips existing objects.
- `01_install_jdbc_driver.sh` — safe to re-run.
- `02_setup_cms.sh` — safe to re-run; skips if CMS already exists.
- `04_deploy_cluster.sh` — if the cluster already exists in CM, exits with a notice.  To redeploy from scratch, delete the cluster in CM and re-run.
- `05_validate_runtime.sh` — read-only, always safe to re-run.

---

## 14. Logs

Bootstrap logs:

```bash
ls /var/log/cloudera-bootstrap/
```

Cloudera Manager server log:

```bash
tail -f /var/log/cloudera-scm-server/cloudera-scm-server.log
```

NiFi logs (on cluster host):

```bash
tail -f /var/log/nifi/nifi-app.log
```

NiFi Registry logs (on cluster host):

```bash
tail -f /var/log/nifiregistry/nifi-registry-app.log
```

---

## 15. Optional: Enable TLS (Auto-TLS)

Use the `utilities/tls/` workflow from **cloudera-install-nonfips** after this kit completes.  Enable Auto-TLS before deploying additional services or enabling Kerberos.  See the base kit `README.md` sections 15–16 for the full sequence.

---

## 16. Optional: Add Ranger

Set `CREATE_EXTRA_DBS=true` in EXPORTS before running `RUN_RUNTIME` to create the `ranger` database.

To add Ranger to an existing cluster after deployment, add the `RANGER` service to the cluster in CM using the Add Service wizard.  Use the database values from EXPORTS:

```
Database host  : <MANAGER_HOST>:5432
Database name  : ranger
Database user  : rangeradmin
Database pass  : Ranger_DB_2026
```

---

## 17. What is NOT included

- Kerberos (MIT KDC or FreeIPA) — add after deploying with Kerberos enabled in CM wizard
- TLS / Auto-TLS — see `utilities/tls/` in the base kit
- Kafka, Schema Registry, Flink, Atlas, Knox, Impala, Kudu — add via CM as needed
- CDSW / CML / CDP Data Services — these require additional infrastructure
