#!/usr/bin/env python3
"""Builds homelab-host_<version>_all.deb without dpkg, so it can be made on a Mac.

usage: build-deb.py <homelab-host.py> <output-dir>
"""
import gzip
import io
import os
import re
import sys
import tarfile
import time

CONTROL = """Package: homelab-host
Version: {version}
Architecture: all
Maintainer: Diego Barreto <BarretoDiego@users.noreply.github.com>
Depends: python3 (>= 3.8), python3-gi, gnome-remote-desktop, openssl
Recommends: polkitd
Section: admin
Priority: optional
Installed-Size: {size}
Description: Host side of the Home Lab remote desktop app
 Prepares a GNOME machine to be reached from the Home Lab app on a Mac:
 desktop sharing over RDP with a virtual screen (works without a monitor),
 a pinned TLS certificate, and the status, file and authentication helpers
 the app calls over SSH. Run "homelab-host setup" once after installing.
"""
README = """homelab-host

  homelab-host setup     liga o compartilhamento de tela (GNOME Remote Desktop)
  homelab-host status    mostra em JSON o que o app Home Lab enxerga

O app do Mac fala com esta máquina só por SSH. Nada fica escutando além do
RDP do próprio GNOME.
"""


def tar_gz(members, mtime):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tar:
        for name, data, mode in members:
            info = tarfile.TarInfo(name)
            info.mtime, info.uname, info.gname, info.mode = mtime, "root", "root", mode
            if data is None:
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
            else:
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=mtime) as gz:
        gz.write(raw.getvalue())
    return out.getvalue()


def ar(members, mtime):
    out = b"!<arch>\n"
    for name, data in members:
        out += ("%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (name, mtime, 0, 0, "100644", len(data))).encode()
        out += data + (b"\n" if len(data) % 2 else b"")
    return out


def main():
    script_path, out_dir = sys.argv[1], sys.argv[2]
    script = open(script_path, "rb").read()
    version = re.search(rb'^VERSION = "([^"]+)"', script, re.M).group(1).decode()
    mtime = int(time.time())
    readme = README.encode()
    data = tar_gz([("./", None, 0o755), ("./usr/", None, 0o755), ("./usr/bin/", None, 0o755),
                   ("./usr/bin/homelab-host", script, 0o755),
                   ("./usr/share/", None, 0o755), ("./usr/share/doc/", None, 0o755),
                   ("./usr/share/doc/homelab-host/", None, 0o755),
                   ("./usr/share/doc/homelab-host/README", readme, 0o644)], mtime)
    control = CONTROL.format(version=version, size=(len(script) + len(readme)) // 1024 + 1).encode()
    control_tar = tar_gz([("./", None, 0o755), ("./control", control, 0o644)], mtime)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "homelab-host_%s_all.deb" % version)
    with open(path, "wb") as f:
        f.write(ar([("debian-binary", b"2.0\n"), ("control.tar.gz", control_tar), ("data.tar.gz", data)], mtime))
    print(path)


if __name__ == "__main__":
    main()
