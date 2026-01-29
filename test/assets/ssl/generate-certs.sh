#!/usr/bin/env bash
set -e

# Script to generate SSL certificates for Valkey/Redis testing
# This creates a CA, server certificate, and client certificate

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Generating SSL certificates in $SCRIPT_DIR ==="

# Clean up old certificates
echo "Cleaning up old certificates..."
rm -f ca-key.pem ca-cert.pem ca-cert.srl
rm -f server-key.pem server-cert.pem server.csr
rm -f client-key.pem client-cert.pem client.csr

# Certificate settings
COUNTRY="LT"
STATE="Test"
LOCALITY="Test"
ORG="Veidrodelis"
DAYS=3650  # 10 years

echo ""
echo "=== Step 1: Generating CA (Certificate Authority) ==="
openssl genrsa -out ca-key.pem 4096
openssl req -new -x509 -nodes -days $DAYS \
  -key ca-key.pem \
  -out ca-cert.pem \
  -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORG/CN=Test CA"
echo "✓ CA certificate generated: ca-cert.pem"
echo "✓ CA private key generated: ca-key.pem"

echo ""
echo "=== Step 2: Generating Server Certificate ==="
openssl genrsa -out server-key.pem 4096
openssl req -new \
  -key server-key.pem \
  -out server.csr \
  -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORG/CN=localhost"
openssl x509 -req -days $DAYS \
  -in server.csr \
  -CA ca-cert.pem \
  -CAkey ca-key.pem \
  -CAcreateserial \
  -out server-cert.pem
echo "✓ Server certificate generated: server-cert.pem"
echo "✓ Server private key generated: server-key.pem"

echo ""
echo "=== Step 3: Generating Client Certificate ==="
openssl genrsa -out client-key.pem 4096
openssl req -new \
  -key client-key.pem \
  -out client.csr \
  -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORG/CN=client"
openssl x509 -req -days $DAYS \
  -in client.csr \
  -CA ca-cert.pem \
  -CAkey ca-key.pem \
  -CAcreateserial \
  -out client-cert.pem
echo "✓ Client certificate generated: client-cert.pem"
echo "✓ Client private key generated: client-key.pem"

echo ""
echo "=== Step 4: Cleaning up temporary files ==="
rm -f server.csr client.csr
echo "✓ Removed CSR files"

echo ""
echo "=== Step 5: Setting permissions ==="
# Private keys need to be readable by Docker containers
chmod 644 server-key.pem client-key.pem ca-key.pem
chmod 644 server-cert.pem client-cert.pem ca-cert.pem
echo "✓ Set permissions to 644 for all files"

echo ""
echo "=== Certificate Generation Complete ==="
echo ""
echo "Generated files:"
ls -lh *.pem ca-cert.srl 2>/dev/null || ls -lh *.pem
echo ""
echo "Certificates are valid for $DAYS days ($(($DAYS / 365)) years)"
echo ""
echo "To use these certificates:"
echo "  - CA: ca-cert.pem"
echo "  - Server: server-cert.pem, server-key.pem"
echo "  - Client: client-cert.pem, client-key.pem"
