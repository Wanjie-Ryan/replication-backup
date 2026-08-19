# DB Ops — MySQL Replication Lab

A standalone, disposable project for practicing primary/replica MySQL replication with Docker, following on from the backup/restore lab. Same philosophy: this exists to internalize the mechanics before applying them to a real database on the ledger project or on Contabo.

## What replication actually is

A **primary** accepts writes and keeps a **binary log (binlog)**, a running record of every change made to the database. A **replica** doesn't get written to directly, instead it runs two background threads:

- **IO thread** — connects to the primary, streams new binlog events over the network, writes them into a local **relay log**.
- **SQL thread** — reads the relay log and actually applies those changes to the replica's own data.

That two-thread split is why replication is *near* real-time rather than instant, there's a small window (replication lag) between "change arrived" and "change applied."

**Replication is not a backup.** It protects against a server dying, not against a mistake. A `DROP TABLE` on the primary replicates to the replica just as faithfully as an `INSERT` does, within seconds, on both sides. For protection against mistakes, see the separate backup/restore README.

## GTID, briefly

This setup uses **GTID (Global Transaction ID)** replication rather than the older manual binlog-file-and-position method. Every transaction gets a unique ID; the replica tracks which GTIDs it's already applied and can auto-discover exactly where to resume from (`SOURCE_AUTO_POSITION=1`), no manual position bookkeeping required.

## docker-compose.yml

```yaml
services:
  mysql-primary:
    image: mysql:8.0
    container_name: dbops_mysql_primary
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: ledger_lab
    command:
      - --server-id=1
      - --log-bin=mysql-bin
      - --gtid-mode=ON
      - --enforce-gtid-consistency=ON
    ports:
      - "3306:3306"
    volumes:
      - dbops_primary_data:/var/lib/mysql
    networks:
      - dbops-network

  mysql-replica:
    image: mysql:8.0
    container_name: dbops_mysql_replica
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
    command:
      - --server-id=2
      - --gtid-mode=ON
      - --enforce-gtid-consistency=ON
      - --read-only=ON
      - --super-read-only=ON
    ports:
      - "3307:3306"
    volumes:
      - dbops_replica_data:/var/lib/mysql
    networks:
      - dbops-network

volumes:
  dbops_primary_data:
  dbops_replica_data:

networks:
  dbops-network:
    driver: bridge
```

**Why the replica has no `MYSQL_DATABASE`/`MYSQL_USER`:** its whole job is to receive `ledger_lab` *through replication*, not bootstrap its own independent copy. If it created the schema itself on startup, it'd be replaying the primary's changes into a database it made up separately, a recipe for divergence.

**Why `--read-only=ON --super-read-only=ON` on the replica:** without this, nothing stops a direct write straight to the replica, which can conflict with an incoming replicated row later. Standard practice, not optional in a real setup. (`super_read_only` also blocks writes from the root user; `read_only` alone does not.)

## Step 1: Clean up any previous single-instance container first

If you had an earlier single-container lab running under the old service name, remove it before starting this one, otherwise you'll hit a port conflict on 3306:

```bash
docker compose down --remove-orphans
docker volume ls          # find any old volume, e.g. dbops_dbops_mysql_data
docker volume rm <old-volume-name>
```

## Step 2: Start both containers

```bash
docker compose up -d
docker compose logs -f mysql-primary
docker compose logs -f mysql-replica
```

Wait for `ready for connections` on both before continuing.

## Step 3: Create a replication user on the primary

```bash
docker exec -it dbops_mysql_primary mysql -u root -p
```
```sql
CREATE USER 'repl_user'@'%' IDENTIFIED BY 'repl_pass';
GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';
FLUSH PRIVILEGES;
```

The replica connects as this dedicated, restricted user, not as `root`. It has exactly one privilege, `REPLICATION SLAVE`, which only allows reading the binlog stream. `'%'` allows connecting from any host, needed since the replica reaches in over the Docker network, not `localhost`.

## Step 4: Point the replica at the primary

```bash
docker exec -it dbops_mysql_replica mysql -u root -p
```
```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-primary',
  SOURCE_USER='repl_user',
  SOURCE_PASSWORD='repl_pass',
  SOURCE_AUTO_POSITION=1,
  GET_SOURCE_PUBLIC_KEY=1;

START REPLICA;
```

`SOURCE_HOST='mysql-primary'` resolves via Docker's internal DNS, same as any other service-to-service name in a compose network.

**`GET_SOURCE_PUBLIC_KEY=1` is required.** MySQL 8 defaults to `caching_sha2_password` authentication, which needs either real TLS or the server's RSA public key to complete the handshake securely. Without this flag, you'll see the replica stuck at `Replica_IO_Running: Connecting` forever, with `Last_IO_Error: ... Authentication requires secure connection.` This flag fetches that public key and fixes it. (A production setup would more likely use real TLS certs between primary and replica; this is the standard pragmatic fix for a non-TLS lab like this one.)

(On MySQL versions before 8.0.23 this was `CHANGE MASTER TO` / `START SLAVE`. `mysql:8.0` pulls a version well past that, so use the syntax above.)

## Step 5: Confirm it's working

```sql
SHOW REPLICA STATUS\G
```

Check specifically for:

```
Replica_IO_Running: Yes
Replica_SQL_Running: Yes
```

Both `Yes` means both threads are alive and the replica is actively receiving and applying changes. If `Replica_IO_Running` is stuck on `Connecting`, see the `GET_SOURCE_PUBLIC_KEY` note above.

## Step 6: Prove it end to end

On the **primary**:

```sql
USE ledger_lab;
CREATE TABLE accounts (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(50), balance DECIMAL(10,2));
INSERT INTO accounts (name, balance) VALUES ('alice', 100.00);
```

Check the **replica**, without touching its config at all:

```bash
docker exec -it dbops_mysql_replica mysql -u root -p -e "SELECT * FROM ledger_lab.accounts;"
```

Alice should be there, having arrived purely via the binlog stream, never written to the replica directly.

## Step 7: Confirm updates and deletes propagate too, not just inserts

MySQL 8 defaults to row-based binlogging, every DML operation (`INSERT`, `UPDATE`, `DELETE`) is recorded uniformly. On the **primary**:

```sql
INSERT INTO accounts (name, balance) VALUES ('bob', 250.75), ('carol', 40.00);
UPDATE accounts SET balance = balance + 50.00 WHERE name = 'alice';
DELETE FROM accounts WHERE name = 'carol';
```

Re-check the replica after each, no commands run there, changes just arrive.

## Step 8: Watch "replication is not backup" happen live

On the **primary**:

```sql
DROP TABLE accounts;
```

Check the replica:

```bash
docker exec -it dbops_mysql_replica mysql -u root -p -e "SELECT * FROM ledger_lab.accounts;"
```

`Table 'ledger_lab.accounts' doesn't exist` — on the replica too, within seconds. Only a real backup taken *before* this moment would get that table back.

## Promoting a replica to primary (manual failover)

A real operational runbook, worth following in exact order. Getting this sequence wrong is how split-brain happens: two nodes both accepting writes, data permanently diverged with no clean merge.

1. **Confirm the primary is truly down.** Don't promote while it might still be reachable by anyone else, even briefly.

   ```bash
   docker compose stop mysql-primary   # simulating the failure
   ```

2. **Stop replication on the replica:**

   ```sql
   STOP REPLICA;
   ```

3. **Clear the replication configuration**, so it no longer thinks it's a replica of anything:

   ```sql
   RESET REPLICA ALL;
   ```

4. **Disable read-only mode**, since this compose file enables it by default:

   ```sql
   SET GLOBAL read_only = OFF;
   SET GLOBAL super_read_only = OFF;
   ```

5. **Point application traffic at the new primary.** Update connection strings, environment variables, or DNS so your app (and any other replicas in the topology) now write here instead. MySQL has no role in this step, it's purely an application/infrastructure change.

6. **Never blindly restart the old primary and assume it's still primary.** If it comes back online, its data may have diverged during the outage. Rebuild it as a *fresh replica* of the newly promoted node instead:

   ```sql
   -- on the old primary, once it's back up
   CHANGE REPLICATION SOURCE TO
     SOURCE_HOST='mysql-replica',   -- now the primary
     SOURCE_USER='repl_user',
     SOURCE_PASSWORD='repl_pass',
     SOURCE_AUTO_POSITION=1,
     GET_SOURCE_PUBLIC_KEY=1;
   START REPLICA;
   ```

In real production, this whole sequence is usually automated (tools like Orchestrator, MHA, or a managed cloud provider's built-in failover) rather than run by hand under incident pressure. Manual is how you learn what those tools are actually doing underneath.

## Notes / gotchas

- `docker ps` shows every container on the machine regardless of project. `docker compose ps` (run from inside this folder) is scoped to just this project's containers.
- If you see `Bind for :::3306 failed: port is already allocated` on `docker compose up`, an old container from a previous version of this project is still holding that port. `docker compose down --remove-orphans` clears it.
- `MYSQL_ROOT_PASSWORD` and `MYSQL_USER`/`MYSQL_PASSWORD` are deliberately different accounts, root for admin work, a scoped user for anything an application would actually connect as. Least privilege, not redundancy.
- Two GTID sets may show up in `Executed_Gtid_Set` after a fix like the one in Step 4, one per server UUID involved across the replication history. Normal bookkeeping, not an error.
- `Replica_SQL_Running: Yes` alone does not mean replication is working, it just means the thread is alive and idle. Always check `Replica_IO_Running` too; both need to be `Yes`.