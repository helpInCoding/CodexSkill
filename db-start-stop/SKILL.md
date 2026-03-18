---
name: db-start-stop
description: Start/stop Oracle databases with srvctl and open/close PDBs via sqlplus. Use for controlled CDB shutdown/startup and PDB state management (all PDBs or a specific PDB), including RAC instances.
---

# Db Start Stop

## Overview

Start or stop a database with `srvctl`, then open/close all PDBs or a specific PDB using `sqlplus / as sysdba`. Use this when performing maintenance, testing, or controlled restarts.

## Workflow Decision Tree

1. Need to stop or start the whole database? Use `srvctl`.
2. Need to close or open PDBs after startup? Use `sqlplus` with the appropriate PDB command.
3. Need to target all PDBs or a specific PDB? Choose `ALL` or `$PDB_NAME`.
4. If the user asks to stop/start or "bounce" the DB, perform the default sequence: stop DB, start DB, then open all PDBs.
5. If the user asks to delete/drop a PDB, always close it first, then drop it. Ask whether to drop with or without datafiles.

## Preconditions

- Confirm `DB_SERVER` host
- Confirm SSH user (oracle, NIS user id, or root)
- Confirm `DB_NAME` and `ORACLE_HOME` path (use lowercase `oracle_home`).
- Set `oracle_sid` using the rule: `oracle_sid=${DB_NAME}1` (lowercase). Example: `orcl` -> `orcl1`, `sachin` -> `sachin1`.
- Confirm `PDB_NAME` only if a specific PDB needs to be opened/closed.
- Ensure `srvctl` is in `PATH` and the Oracle environment is set.
- For RAC, use `instances=all` in PDB commands.
- If unable to connect because of `oracle_sid`, ask the user to confirm the SID.

## Stop or Start the Database (CDB)

If Grid Infrastructure / Oracle Restart is installed and `srvctl` is available, use `srvctl`.
Otherwise use `sqlplus / as sysdba` with `startup` / `shutdown immediate`.

```bash
srvctl stop database -d $DB_NAME
srvctl start database -d $DB_NAME
```

Optional status check:

```bash
srvctl status database -d $DB_NAME
```

## Close or Open All PDBs

```sql
sqlplus / as sysdba
ALTER PLUGGABLE DATABASE ALL CLOSE IMMEDIATE INSTANCES=ALL;
ALTER PLUGGABLE DATABASE ALL OPEN INSTANCES=ALL;
```

## Default Bounce Behavior

When the user requests a DB stop/start or "bounce", do this without further prompts:

1. Stop the DB with `srvctl`.
2. Start the DB with `srvctl`.
3. Open all PDBs with `ALTER PLUGGABLE DATABASE ALL OPEN INSTANCES=ALL;`.

## Close or Open a Specific PDB

```sql
sqlplus / as sysdba
ALTER PLUGGABLE DATABASE $PDB_NAME CLOSE IMMEDIATE INSTANCES=ALL;
ALTER PLUGGABLE DATABASE $PDB_NAME OPEN READ WRITE INSTANCES=ALL;
```

## Drop a Specific PDB

Ask the user whether to drop with or without datafiles. Always close the PDB first, then drop it, and show the PDB list.

```sql
sqlplus / as sysdba
ALTER PLUGGABLE DATABASE $PDB_NAME CLOSE IMMEDIATE INSTANCES=ALL;
DROP PLUGGABLE DATABASE $PDB_NAME INCLUDING DATAFILES;
SHOW PDBS;
```

## Verification

```sql
sqlplus / as sysdba
SHOW PDBS;
```

## Scripted Workflow

Always use the bundled script to run the full workflow over passwordless SSH:

```bash
scripts/db_start_stop.sh
```

Notes:
- The script supports `bounce` as a DB action, which defaults to: stop DB, start DB, open all PDBs.
- The script always lists PDBs at the end (`SHOW PDBS`).
- The script auto-detects `srvctl` on the DB server; if not found it uses `sqlplus` startup/shutdown.
