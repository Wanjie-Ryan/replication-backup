#!/bin/bash
# restore.sh — restores a given backup file into ledger_lab
# usage: ./restore.sh backups/backup_2026-08-18_1430.sql

if [ -z "$1" ]; then
    echo "Usage: ./restore.sh <path-to-backup.sql>"
    exit 1
fi

read -p "This will overwrite current data in ledger_lab. Continue? (y/n) " confirm
if [ "$confirm" != "y" ]; then
    echo "Cancelled."
    exit 0
fi

docker exec -i dbops_mysql mysql -u root -prootpass ledger_lab < "$1"
echo "Restored from $1"