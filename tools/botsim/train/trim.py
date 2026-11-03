import os
import struct
import sys

from relabel import skip_record


def complete_end(data):
    pos = 32
    (tl,) = struct.unpack_from("<H", data, pos)
    pos += 2 + tl
    good = pos
    while pos < len(data):
        try:
            if data[pos:pos + 4] != b"RUN2":
                break
            (nrec,) = struct.unpack_from("<I", data, pos + 4)
            pos += 16
            for _ in range(nrec):
                pos = skip_record(data, pos)
        except struct.error:
            break
        if pos > len(data):
            break
        good = pos
    return good


def main(paths):
    for p in paths:
        data = open(p, "rb").read()
        end = complete_end(data) if len(data) >= 34 else len(data) + 1
        if end > len(data):
            os.remove(p)
            print(f"removed {p}: {len(data)} bytes, no complete header")
        elif end < len(data):
            open(p, "wb").write(data[:end])
            print(f"trimmed {p}: {len(data)} -> {end}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
