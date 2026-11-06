#!/usr/bin/env python3
"""Report PEM trust files as JSON: file sha256, the CRC32C Redpanda exports as
vectorized_tls_trust_file_crc32c, and the sha256 fingerprint of every certificate."""
import base64
import hashlib
import json
import re
import sys

PEM = re.compile(rb"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----", re.S)


def crc32c(raw):
    crc = 0xFFFFFFFF
    for byte in raw:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82F63B78 if crc & 1 else 0)
    return crc ^ 0xFFFFFFFF


def fingerprint(body):
    return hashlib.sha256(base64.b64decode(b"".join(body.split()))).hexdigest()


def report(path):
    with open(path, "rb") as handle:
        raw = handle.read()
    return {
        "sha256": hashlib.sha256(raw).hexdigest(),
        "crc32c": str(crc32c(raw)),
        "certificates": [fingerprint(body) for body in PEM.findall(raw)],
    }


print(json.dumps({path: report(path) for path in sys.argv[1:]}))
