#!/usr/bin/env python3
"""Verify one detached release signature of a downloaded asset, and fail closed.

Usage (always run as `python3 -I`, so nothing is imported from the working directory):

    verify-release-sig.py ed25519 <sig> <data> <keyfile> [<copy-out>]
    verify-release-sig.py mldsa65 <sig> <data> <keyfile>
    verify-release-sig.py check-keys ed25519|mldsa65 <keyfile>

A key file holds one base64 public key per line; blank lines and lines starting with '#' are
ignored; more than one key is allowed so a rotation can trust the old and the new key at once.
The file is the trust anchor, so a file that holds any byte other than printable ASCII and a
line feed (a carriage return, a tab, a NUL, a byte above 0x7f) is refused whole before a key
is read.

Exit status: 0 verified, 1 the signature is bad (wrong length, over the cap, not made by a
listed key), 2 the local key file is malformed or missing, 3 the installed `cryptography`
cannot verify ML-DSA-65, 4 the verified bytes could not be kept. Anything else (a crash)
is not a verdict and the caller must treat it as a refusal.

With <copy-out>, the exact buffer the Ed25519 key vouched for is written there (created
exclusively, mode 0600), so the caller can read every field from the bytes that were verified
and never from the file again.
"""
import base64
import binascii
import os
import sys

ED25519_KEY_BYTES = 32
ED25519_SIG_BYTES = 64
MLDSA65_KEY_BYTES = 1952
MLDSA65_SIG_BYTES = 3309
# A hostile sidecar is never read whole before its length is known.
MAX_SIG_BYTES = 4096


def die(code, message):
    sys.stderr.write(message + "\n")
    sys.exit(code)


def read_keys(path, want_bytes, label):
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as err:
        die(2, f"cannot read the {label} release public key file {path}: {err}")
    stray = [b for b in raw if not (0x20 <= b <= 0x7E or b == 0x0A)]
    if stray:
        die(2, f"{path} holds {len(stray)} byte(s) that are neither printable ASCII nor a line feed; "
               "refusing it as a broken trust anchor before reading any key")
    keys = []
    for line in raw.decode("ascii").split("\n"):
        line = "".join(line.split())
        if not line or line.startswith("#"):
            continue
        line += "=" * (-len(line) % 4)
        try:
            key = base64.b64decode(line, validate=True)
        except (ValueError, binascii.Error):
            die(2, f"malformed {label} release public key in {path}: not base64")
        if len(key) != want_bytes:
            die(2, f"malformed {label} release public key in {path}: {len(key)} bytes, "
                   f"not a {want_bytes}-byte key")
        keys.append(key)
    return keys


def read_signature(path, want_bytes, label):
    try:
        with open(path, "rb") as handle:
            sig = handle.read(MAX_SIG_BYTES + 1)
    except OSError as err:
        die(1, f"cannot read the {label} signature file: {err}")
    if len(sig) > MAX_SIG_BYTES:
        die(1, f"the {label} signature file is over {MAX_SIG_BYTES} bytes")
    if len(sig) != want_bytes:
        die(1, f"the {label} signature is {len(sig)} bytes, expected exactly {want_bytes}")
    return sig


def verify_ed25519(sig_path, data_path, key_path, copy_path):
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    raw_keys = read_keys(key_path, ED25519_KEY_BYTES, "Ed25519")
    if not raw_keys:
        die(2, f"{key_path} has no keys")
    keys = [Ed25519PublicKey.from_public_bytes(raw) for raw in raw_keys]
    sig = read_signature(sig_path, ED25519_SIG_BYTES, "Ed25519")
    # The caller bounds the size of the asset before calling.
    with open(data_path, "rb") as handle:
        data = handle.read()
    for key in keys:
        try:
            key.verify(sig, data)
        except InvalidSignature:
            continue
        if copy_path:
            try:
                fd = os.open(copy_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, "wb") as copy:
                    copy.write(data)
            except OSError as err:
                die(4, f"cannot keep the verified bytes: {err}")
        return 0
    die(1, "the Ed25519 signature is not made by any listed release key")


def verify_mldsa65(sig_path, data_path, key_path):
    raw_keys = read_keys(key_path, MLDSA65_KEY_BYTES, "ML-DSA-65")
    if not raw_keys:
        die(1, "an ML-DSA-65 signature is present and no ML-DSA-65 release public key is configured; "
               "refusing a signature that cannot be checked")
    sig = read_signature(sig_path, MLDSA65_SIG_BYTES, "ML-DSA-65")
    from cryptography.exceptions import InvalidSignature, UnsupportedAlgorithm

    try:
        from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PublicKey

        keys = [MLDSA65PublicKey.from_public_bytes(raw) for raw in raw_keys]
    except (ImportError, UnsupportedAlgorithm) as err:
        die(3, f"the installed cryptography cannot verify ML-DSA-65 ({err}); refusing rather than skipping it")
    except ValueError as err:
        die(2, f"malformed ML-DSA-65 release public key: {err}")
    with open(data_path, "rb") as handle:
        data = handle.read()
    for key in keys:
        try:
            key.verify(sig, data)
            return 0
        except InvalidSignature:
            continue
    die(1, "the ML-DSA-65 signature is not made by any listed release key")


def main(argv):
    if len(argv) >= 4 and argv[1] == "check-keys":
        size, label = {"ed25519": (ED25519_KEY_BYTES, "Ed25519"),
                       "mldsa65": (MLDSA65_KEY_BYTES, "ML-DSA-65")}.get(argv[2], (None, None))
        if size is None:
            die(2, f"unknown algorithm {argv[2]}")
        read_keys(argv[3], size, label)
        return 0
    if len(argv) in (5, 6) and argv[1] == "ed25519":
        return verify_ed25519(argv[2], argv[3], argv[4], argv[5] if len(argv) == 6 else None)
    if len(argv) == 5 and argv[1] == "mldsa65":
        return verify_mldsa65(argv[2], argv[3], argv[4])
    die(2, "usage: verify-release-sig.py ed25519 <sig> <data> <keyfile> [<copy-out>] | "
           "mldsa65 <sig> <data> <keyfile> | check-keys ed25519|mldsa65 <keyfile>")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
