#!/bin/bash
echo "=== GO BUILD TRIGGERED ==="
cd C:/mySpace/CorssLink/poc
go build ./... 2>&1
echo "=== GO TEST ==="
go test ./pairing/ ./ollama/ -v 2>&1
