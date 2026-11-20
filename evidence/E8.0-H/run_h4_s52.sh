#!/bin/bash
# E8.0-H4: LiteLLM backup K1 vs K2 reconciliation. READ-ONLY (no restore, no new dump, no writes).
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
B=/home/saber/backups
K1="$B/e63-20261116-153338/litellm-personal-20261116-153338.sql.gz"
K2="$B/e63-b2-20261117-000829/litellm-personal.sql"
echo "=== K1 (gzipped full dump) ==="
ls -la "$K1"
sha256sum "$K1"
gzip -l "$K1"
echo "=== K2 (plain full dump) ==="
ls -la "$K2"
sha256sum "$K2"
echo "=== dump headers (K2 plain) ==="
head -8 "$K2" | cut -c1-160
echo "=== dump headers (K1 gunzipped) ==="
gzip -dc "$K1" | head -8 | cut -c1-160
echo "=== statement_timestamp lines (provenance) ==="
echo "K1:"; gzip -dc "$K1" | grep -m2 -E 'statement_timestamp|Dumped from database' | cut -c1-160
echo "K2:"; grep -m2 -E 'statement_timestamp|Dumped from database' "$K2" | cut -c1-160
echo "=== table set diff ==="
diff <(gzip -dc "$K1" | grep -oE '^CREATE TABLE [^ (]+' | sort) \
     <(grep -oE '^CREATE TABLE [^ (]+' "$K2" | sort) && echo "TABLES_IDENTICAL"
echo "K1 table count: $(gzip -dc "$K1" | grep -cE '^CREATE TABLE ')"
echo "K2 table count: $(grep -cE '^CREATE TABLE ' "$K2")"
echo "=== COPY data sections ==="
echo "K1: $(gzip -dc "$K1" | grep -cE '^COPY ')"
echo "K2: $(grep -cE '^COPY ' "$K2")"
echo "=== index counts ==="
echo "K1: $(gzip -dc "$K1" | grep -cE '^CREATE INDEX')"
echo "K2: $(grep -cE '^CREATE INDEX' "$K2")"
echo "END H4"
