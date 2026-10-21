#!/bin/sh
# A test CA and a server certificate for the hosts tls and tls-flat, written
# in both layouts the image reads: /ssl/live/<domain>/ and /ssl/<domain>.*
set -eu
cd /tmp
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=e2e-ca \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
    -keyout ca.key -out ca.pem
openssl req -newkey rsa:2048 -nodes -subj /CN=tls -keyout server.key -out server.csr
printf 'subjectAltName=DNS:tls,DNS:tls-flat,DNS:tls-locked\n' > server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 \
    -extfile server.ext -out server.pem

mkdir -p /ssl-live/live/example.com
cp server.pem /ssl-live/live/example.com/cert.pem
cp server.key /ssl-live/live/example.com/privkey.pem
cp ca.pem /ssl-live/live/example.com/chain.pem
chmod 600 /ssl-live/live/example.com/privkey.pem

cp server.pem /ssl-flat/example.com.pem
cp server.key /ssl-flat/example.com.key
cp ca.pem /ssl-flat/example.com-ca.crt
chmod 600 /ssl-flat/example.com.key

mkdir -p /ssl-locked/live/example.com
cp server.pem /ssl-locked/live/example.com/cert.pem
cp server.key /ssl-locked/live/example.com/privkey.pem
cp ca.pem /ssl-locked/live/example.com/chain.pem
chmod 000 /ssl-locked/live/example.com/privkey.pem
