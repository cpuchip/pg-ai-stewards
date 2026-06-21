#!/usr/bin/env bash
# Read-only DB access for the Hinge reviewer. Any write is rejected
# (default_transaction_read_only). Usage: bash query.sh "SELECT ... ;"
sql="$1"
printf 'SET default_transaction_read_only = on;\n%s\n' "$sql" \
  | docker exec -i stewards-oss-pg psql -U stewards -d stewards -P pager=off
