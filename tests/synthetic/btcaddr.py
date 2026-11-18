#!/usr/bin/env python3
"""Independent secp256k1 private key -> P2PKH address derivation.

Pure Python, no third-party packages. Used to cross-check BitCrack's GPU
results against a separate implementation. Not constant-time; for test
vectors and synthetic keys only.

Usage:
    python btcaddr.py <hex-private-key> [...]     # print both addresses
    python btcaddr.py --selftest                  # check known vectors
"""
import hashlib
import sys

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def _add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0] and (a[1] + b[1]) % P == 0:
        return None
    if a == b:
        lam = 3 * a[0] * a[0] * pow(2 * a[1], -1, P) % P
    else:
        lam = (b[1] - a[1]) * pow(b[0] - a[0], -1, P) % P
    x = (lam * lam - a[0] - b[0]) % P
    return (x, (lam * (a[0] - x) - a[1]) % P)


def pubkey(k):
    if not 0 < k < N:
        raise ValueError("private key out of range")
    r, q = None, G
    while k:
        if k & 1:
            r = _add(r, q)
        q = _add(q, q)
        k >>= 1
    return r


def _ripemd160(data):
    try:
        return hashlib.new("ripemd160", data).digest()
    except ValueError:  # OpenSSL 3 builds without legacy provider
        return _ripemd160_py(data)


def _ripemd160_py(msg):
    # Reference RIPEMD-160 (Dobbertin, Bosselaers, Preneel).
    rl = lambda x, n: ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF
    f = [lambda x, y, z: x ^ y ^ z,
         lambda x, y, z: (x & y) | (~x & z),
         lambda x, y, z: (x | ~y) ^ z,
         lambda x, y, z: (x & z) | (y & ~z),
         lambda x, y, z: x ^ (y | ~z)]
    KL = [0, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E]
    KR = [0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0]
    ZL = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8,
          3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12,1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2,
          4,0,5,9,7,12,2,10,14,1,3,8,11,6,15,13]
    ZR = [5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12,6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2,
          15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13,8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14,
          12,15,10,4,1,5,8,7,6,2,13,14,0,3,9,11]
    SL = [11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8,7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12,
          11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5,11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12,
          9,15,5,11,6,8,13,12,5,12,13,14,11,8,5,6]
    SR = [8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6,9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11,
          9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5,15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8,
          8,5,12,9,12,5,14,6,8,13,6,5,15,13,11,11]
    h = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    ml = len(msg) * 8
    msg = msg + b"\x80" + b"\x00" * ((55 - len(msg)) % 64) + ml.to_bytes(8, "little")
    for i in range(0, len(msg), 64):
        X = [int.from_bytes(msg[i + 4 * j:i + 4 * j + 4], "little") for j in range(16)]
        al, bl, cl, dl, el = h
        ar, br, cr, dr, er = h
        for j in range(80):
            r = j // 16
            t = (rl((al + (f[r](bl, cl, dl) & 0xFFFFFFFF) + X[ZL[j]] + KL[r]) & 0xFFFFFFFF, SL[j]) + el) & 0xFFFFFFFF
            al, el, dl, cl, bl = el, dl, rl(cl, 10), bl, t
            t = (rl((ar + (f[4 - r](br, cr, dr) & 0xFFFFFFFF) + X[ZR[j]] + KR[r]) & 0xFFFFFFFF, SR[j]) + er) & 0xFFFFFFFF
            ar, er, dr, cr, br = er, dr, rl(cr, 10), br, t
        t = (h[1] + cl + dr) & 0xFFFFFFFF
        h[1] = (h[2] + dl + er) & 0xFFFFFFFF
        h[2] = (h[3] + el + ar) & 0xFFFFFFFF
        h[3] = (h[4] + al + br) & 0xFFFFFFFF
        h[4] = (h[0] + bl + cr) & 0xFFFFFFFF
        h[0] = t
    return b"".join(x.to_bytes(4, "little") for x in h)


def b58check(payload):
    data = payload + hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    n = int.from_bytes(data, "big")
    out = ""
    while n:
        n, r = divmod(n, 58)
        out = B58[r] + out
    return "1" * (len(data) - len(data.lstrip(b"\x00"))) + out


def address(k, compressed=True):
    x, y = pubkey(k)
    if compressed:
        pub = bytes([2 + (y & 1)]) + x.to_bytes(32, "big")
    else:
        pub = b"\x04" + x.to_bytes(32, "big") + y.to_bytes(32, "big")
    return b58check(b"\x00" + _ripemd160(hashlib.sha256(pub).digest()))


# Widely published vectors. Key 1 is the generator point; the puzzle keys are
# solved, publicly documented puzzle-transaction keys used only as vectors.
VECTORS = [
    (1, True, "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH"),
    (1, False, "1EHNa6Q4Jz2uvNExL497mE43ikXhwF6kZm"),
    (0xD2C55, True, "1HsMJxNiV7TLxmoF6uJNkydxPFDog4NQum"),  # puzzle #20
]


def selftest():
    ok = _ripemd160_py(b"abc").hex() == "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc"
    print(("PASS" if ok else "FAIL"), "ripemd160 pure-python vector")
    for k, c, want in VECTORS:
        got = address(k, c)
        good = got == want
        ok &= good
        print(("PASS" if good else "FAIL"), hex(k), "compressed" if c else "uncompressed", got)
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    if sys.argv[1] == "--selftest":
        sys.exit(selftest())
    for a in sys.argv[1:]:
        k = int(a, 16)
        print(hex(k), address(k, True), address(k, False))
