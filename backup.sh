#!/bin/bash
# backup.sh — dumps ledger_lab from the dbops_mysql container to a timestamped file

TIMESTAMP=$(date +%F_%H%M)
BACKUP_DIR="/home/wanjie/db-ops/backups"
FILE="$BACKUP_DIR/backup_$TIMESTAMP.sql"

mkdir -p "$BACKUP_DIR"

docker exec dbops_mysql mysqldump -u root -prootpass ledger_lab > "$FILE"

if [ $? -eq 0 ]; then
    echo "$(date): backup succeeded -> $FILE" >> "$BACKUP_DIR/backup.log"
else
    echo "$(date): backup FAILED" >> "$BACKUP_DIR/backup.log"
fi

# delete backups older than 7 days
find "$BACKUP_DIR" -name "backup_*.sql" -mtime +7 -delete