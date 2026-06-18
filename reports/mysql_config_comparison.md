# MySQL Standard vs Advanced — Configuration Comparison

Generated from:

- `data/standard_mysql_config.txt`  
- `data/advanced_mysql_config.txt`

## Summary

| Category | Standard | Advanced |
| :---- | :---- | :---- |
| Engine | MySQL 8.4.8 (Source distribution) | Percona Server 8.4.8-8 |
| Buffer pool | \~85 GiB (64 instances) | 128 MiB (1 instance) |
| Redo log | \~36.5 GiB | 48 MiB |
| Max connections | 12,801 | 512 |

Standard is configured for a much larger node than Advanced. Benchmark results should be interpreted with that sizing difference in mind.

## Full comparison

| Setting | Standard | Advanced | Match |
| :---- | :---- | :---- | :---- |
| `version` | 8.4.8 | 8.4.8-8 | No |
| `version_comment` | Source distribution | Percona Server (GPL), Release 8, Revision 1c288264 | No |
| `innodb_buffer_pool_size` | 91,268,055,040 (\~85 GiB) | 134,217,728 (128 MiB) | No |
| `innodb_buffer_pool_instances` | 64 | 1 | No |
| `innodb_log_file_size` | 39,225,131,008 (\~36.5 GiB) | 50,331,648 (48 MiB) | No |
| `innodb_flush_log_at_trx_commit` | 1 | 1 | Yes |
| `innodb_io_capacity` | 10,000 | 10,000 | Yes |
| `innodb_io_capacity_max` | 20,000 | 20,000 | Yes |
| `innodb_read_io_threads` | 16 | 16 | Yes |
| `innodb_write_io_threads` | 4 | 4 | Yes |
| `max_connections` | 12,801 | 512 | No |
| `sql_require_primary_key` | 1 | 1 | Yes |
| `transaction_isolation` | REPEATABLE-READ | REPEATABLE-READ | Yes |
| `binlog_format` | ROW | ROW | Yes |
| `sync_binlog` | 1 | 1 | Yes |
| `character_set_server` | utf8mb4 | utf8mb4 | Yes |
| `collation_server` | utf8mb4\_0900\_ai\_ci | utf8mb4\_0900\_ai\_ci | Yes |

## Raw values

### Standard

```
version:                      8.4.8
version_comment:              Source distribution
innodb_buffer_pool_size:      91268055040
innodb_buffer_pool_instances: 64
innodb_log_file_size:         39225131008
innodb_flush_log_at_trx_commit: 1
innodb_io_capacity:           10000
innodb_io_capacity_max:       20000
innodb_read_io_threads:       16
innodb_write_io_threads:      4
max_connections:              12801
sql_require_primary_key:      1
transaction_isolation:        REPEATABLE-READ
binlog_format:                ROW
sync_binlog:                  1
character_set_server:         utf8mb4
collation_server:             utf8mb4_0900_ai_ci
```

### Advanced

```
version:                      8.4.8-8
version_comment:              Percona Server (GPL), Release 8, Revision 1c288264
innodb_buffer_pool_size:      134217728
innodb_buffer_pool_instances: 1
innodb_log_file_size:         50331648
innodb_flush_log_at_trx_commit: 1
innodb_io_capacity:           10000
innodb_io_capacity_max:       20000
innodb_read_io_threads:       16
innodb_write_io_threads:      4
max_connections:              512
sql_require_primary_key:      1
transaction_isolation:        REPEATABLE-READ
binlog_format:                ROW
sync_binlog:                  1
character_set_server:         utf8mb4
collation_server:             utf8mb4_0900_ai_ci
```

## Commands used

```sql
source benchmark.conf

mysql -h "${ADVANCED_MYSQL_HOST}" -P "${ADVANCED_MYSQL_PORT}" \
  -u "${ADVANCED_MYSQL_USER}" -p"${ADVANCED_MYSQL_PASSWORD}" \
  --ssl-mode=REQUIRED "${ADVANCED_MYSQL_DB}" \
  -e "
SELECT
  VERSION() AS version,
  @@version_comment AS version_comment,
  @@innodb_buffer_pool_size AS innodb_buffer_pool_size,
  @@innodb_buffer_pool_instances AS innodb_buffer_pool_instances,
  @@innodb_log_file_size AS innodb_log_file_size,
  @@innodb_flush_log_at_trx_commit AS innodb_flush_log_at_trx_commit,
  @@innodb_io_capacity AS innodb_io_capacity,
  @@innodb_io_capacity_max AS innodb_io_capacity_max,
  @@innodb_read_io_threads AS innodb_read_io_threads,
  @@innodb_write_io_threads AS innodb_write_io_threads,
  @@max_connections AS max_connections,
  @@global.sql_require_primary_key AS sql_require_primary_key,
  @@global.transaction_isolation AS transaction_isolation,
  @@global.binlog_format AS binlog_format,
  @@global.sync_binlog AS sync_binlog,
  @@character_set_server AS character_set_server,
  @@collation_server AS collation_server;
" | tee advanced_mysql_config.txtmysql -h "${STANDARD_MYSQL_HOST}" -P "${STANDARD_MYSQL_PORT}" \
  -u "${STANDARD_MYSQL_USER}" -p"${STANDARD_MYSQL_PASSWORD}" \
  --ssl-mode=REQUIRED "${STAGE_MYSQL_DB:-${STANDARD_MYSQL_DB}}" \
  -e "
SELECT
  VERSION() AS version,
  @@version_comment AS version_comment,
  @@innodb_buffer_pool_size AS innodb_buffer_pool_size,
  @@innodb_buffer_pool_instances AS innodb_buffer_pool_instances,
  @@innodb_log_file_size AS innodb_log_file_size,
  @@innodb_flush_log_at_trx_commit AS innodb_flush_log_at_trx_commit,
  @@innodb_io_capacity AS innodb_io_capacity,
  @@innodb_io_capacity_max AS innodb_io_capacity_max,
  @@innodb_read_io_threads AS innodb_read_io_threads,
  @@innodb_write_io_threads AS innodb_write_io_threads,
  @@max_connections AS max_connections,
  @@global.sql_require_primary_key AS sql_require_primary_key,
  @@global.transaction_isolation AS transaction_isolation,
  @@global.binlog_format AS binlog_format,
  @@global.sync_binlog AS sync_binlog,
  @@character_set_server AS character_set_server,
  @@collation_server AS collation_server;
" | tee standard_mysql_config.txt
```

## Notes

- **Matching settings:** durability (`innodb_flush_log_at_trx_commit`, `sync_binlog`), IO tuning, isolation level, binlog format, and charset/collation are the same.  
- **Sizing gap:** Standard's buffer pool is \~678× larger and its redo log is \~780× larger than Advanced.  
- **Engine difference:** Advanced runs Percona Server; Standard runs vanilla MySQL.  
- For a fair edition comparison, use clusters with the same plan size (CPU, RAM, storage).

