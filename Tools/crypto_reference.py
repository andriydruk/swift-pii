#!/usr/bin/env python3
"""Generate AES-CBC interop vectors from Presidio's own cipher.

Encryption is not byte-reproducible — `aes_cipher.py:24` calls `os.urandom(16)`
per invocation — so "byte-compatible" is the wrong bar. Two things are testable
and both are here:

  * **Known-answer vectors** with a fixed IV, which pin the cipher, the PKCS#7
    padding and the URL-safe base64 encoding exactly.
  * **Real ciphertexts** produced by Presidio with its random IV, which the
    Swift side must decrypt to the original plaintext. This is the property that
    actually matters: data encrypted by the Python service must be readable by
    the Swift one.

Usage:
    python3 Tools/crypto_reference.py --presidio <checkout> \\
        --out Tests/PresidioConformance/Fixtures/crypto_reference.json
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys

# Keys at each supported size, plus non-ASCII and emoji plaintexts to catch
# UTF-8 handling that a pure-ASCII corpus would miss.
KEYS = {
    "aes128": "0123456789abcdef",
    "aes192": "0123456789abcdef01234567",
    "aes256": "0123456789abcdef0123456789abcdef",
}

PLAINTEXTS = [
    "",
    "a",
    "text_for_encryption",
    "My name is Bond, James Bond",
    "x" * 15,   # one byte short of a block
    "x" * 16,   # exactly one block -> a full block of padding
    "x" * 17,
    "x" * 31,
    "x" * 32,
    "café naïve",
    "\U0001F608 devil \U0001F608",
    "田中さん",
    "שלום עולם",
    "line1\nline2\ttab",
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--presidio", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    pkg = os.path.join(args.presidio, "presidio-anonymizer")
    if not os.path.isdir(pkg):
        print(f"error: {pkg} not found", file=sys.stderr)
        return 2
    sys.path.insert(0, pkg)

    from presidio_anonymizer.operators.aes_cipher import AESCipher
    from cryptography.hazmat.primitives import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    def fixed_iv_encrypt(key: bytes, text: str, iv: bytes) -> str:
        """Presidio's encrypt with the IV pinned, so the output is stable."""
        padder = padding.PKCS7(algorithms.AES.block_size).padder()
        padded = padder.update(text.encode("utf8")) + padder.finalize()
        encryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
        ciphertext = encryptor.update(padded) + encryptor.finalize()
        return base64.urlsafe_b64encode(iv + ciphertext).decode()

    known_answer = []
    interop = []

    for key_name, key_text in KEYS.items():
        key = key_text.encode("utf8")
        for index, plaintext in enumerate(PLAINTEXTS):
            # A deterministic but non-trivial IV per case.
            iv = bytes((index * 7 + i * 13) % 256 for i in range(16))
            known_answer.append({
                "key_name": key_name,
                "key": key_text,
                "iv": list(iv),
                "plaintext": plaintext,
                "ciphertext": fixed_iv_encrypt(key, plaintext, iv),
            })
            # Presidio's real encrypt path, random IV.
            interop.append({
                "key_name": key_name,
                "key": key_text,
                "plaintext": plaintext,
                "ciphertext": AESCipher.encrypt(key, plaintext),
            })

    # Round-trip sanity on the Python side, so a broken generator is caught here
    # rather than showing up as a Swift failure.
    for case in interop:
        back = AESCipher.decrypt(case["key"].encode("utf8"), case["ciphertext"])
        assert back == case["plaintext"], f"python round-trip failed for {case!r}"

    invalid_key_sizes = [len(k) for k in ["short", "x" * 15, "x" * 17, "x" * 33]]

    payload = {
        "schema_version": 1,
        "note": (
            "Encryption uses a random IV upstream, so only decryption is "
            "byte-reproducible. known_answer pins the cipher with a fixed IV; "
            "interop must decrypt to plaintext."
        ),
        "stats": {
            "known_answer": len(known_answer),
            "interop": len(interop),
        },
        "valid_key_sizes": [16, 24, 32],
        "invalid_key_sizes": invalid_key_sizes,
        "known_answer": known_answer,
        "interop": interop,
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)
        fh.write("\n")

    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  known-answer vectors {len(known_answer)}")
    print(f"  interop ciphertexts  {len(interop)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
