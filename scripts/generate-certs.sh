#!/bin/sh

# SSL Certificate Generation Script for H2 vs H3 Demo
# Generates self-signed certificates for localhost and 127.0.0.1

set -e

CERT_DIR="/certs"
CERT_FILE="$CERT_DIR/server.crt"
KEY_FILE="$CERT_DIR/server.key"
CONFIG_FILE="$CERT_DIR/openssl.conf"

echo "Starting SSL certificate generation..."

# Install OpenSSL if not available
if ! command -v openssl >/dev/null 2>&1; then
    echo "Installing OpenSSL..."
    apk add --no-cache openssl
fi

# Create certificate directory if it doesn't exist
mkdir -p "$CERT_DIR"

# Create OpenSSL configuration file for SAN (Subject Alternative Names)
cat > "$CONFIG_FILE" << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
C=US
ST=Demo
L=Demo
O=H2vsH3Demo
OU=Demo
CN=localhost

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = *.localhost
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

echo "Generating private key..."
openssl genrsa -out "$KEY_FILE" 2048

echo "Generating certificate signing request..."
openssl req -new -key "$KEY_FILE" -out "$CERT_DIR/server.csr" -config "$CONFIG_FILE"

echo "Generating self-signed certificate..."
openssl x509 -req -in "$CERT_DIR/server.csr" -signkey "$KEY_FILE" -out "$CERT_FILE" \
    -days 365 -extensions v3_req -extfile "$CONFIG_FILE"

# Set appropriate permissions
chmod 644 "$CERT_FILE"
chmod 600 "$KEY_FILE"

# Verify certificate
echo "Verifying generated certificate..."
openssl x509 -in "$CERT_FILE" -text -noout | grep -A 5 "Subject Alternative Name" || true

# Clean up temporary files
rm -f "$CERT_DIR/server.csr" "$CONFIG_FILE"

echo "SSL certificate generation completed successfully!"
echo "Certificate: $CERT_FILE"
echo "Private Key: $KEY_FILE"
echo "Valid for: localhost, *.localhost, 127.0.0.1, ::1"
echo "Validity: 365 days"
