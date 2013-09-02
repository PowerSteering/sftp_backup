#!/usr/bin/sh
# Decrypt openssl encrypted file

CIPHER='aes-256-cbc'

echo "Input File: $1"
echo "Output File: $1.dec"

openssl $CIPHER -d -salt -in $1 -out $1.dec
