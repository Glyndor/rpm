#!/usr/bin/env python3
"""Throwaway release keys and signatures for the tests (run as `python3 -I`).

    release-key.py gen-ed <dir>          writes <dir>/ed.seed and <dir>/ed.b64 (the public key)
    release-key.py sign-ed <seed> <file> writes <file>.sig, 64 raw bytes
    release-key.py gen-pq <dir>          writes <dir>/pq.seed and <dir>/pq.b64 (needs ML-DSA)
    release-key.py sign-pq <seed> <file> writes <file>.mldsa65.sig, 3309 raw bytes
"""
import base64
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def gen(dirname, seed_name, pub_name, key_type):
    key = key_type.generate()
    seed = key.private_bytes_raw()
    with open(f"{dirname}/{seed_name}", "wb") as handle:
        handle.write(seed)
    with open(f"{dirname}/{pub_name}", "w", encoding="ascii") as handle:
        handle.write(base64.b64encode(key.public_key().public_bytes_raw()).decode("ascii") + "\n")


def main(argv):
    if argv[1] == "gen-ed":
        gen(argv[2], "ed.seed", "ed.b64", Ed25519PrivateKey)
    elif argv[1] == "sign-ed":
        key = Ed25519PrivateKey.from_private_bytes(open(argv[2], "rb").read())
        with open(argv[3], "rb") as handle, open(argv[3] + ".sig", "wb") as out:
            out.write(key.sign(handle.read()))
    elif argv[1] in ("gen-pq", "sign-pq"):
        from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey

        if argv[1] == "gen-pq":
            gen(argv[2], "pq.seed", "pq.b64", MLDSA65PrivateKey)
        else:
            key = MLDSA65PrivateKey.from_seed_bytes(open(argv[2], "rb").read())
            with open(argv[3], "rb") as handle, open(argv[3] + ".mldsa65.sig", "wb") as out:
                out.write(key.sign(handle.read()))
    else:
        sys.exit("unknown command")


if __name__ == "__main__":
    main(sys.argv)
