# Third-party components

Nothing below is included in this repository. Each piece is downloaded from
its original source on your computer when you run `build.sh`, and some of it
ends up inside the image you build, for your own use.

| Component | Source | License | In the built image? |
|---|---|---|---|
| Harman Kardon Invoke OTA2 package (firmware, USB driver, flashing tool) | Harman's download link in `build.sh` | Harman's terms | Yes (it is the base image) |
| shairport-sync (pinned commit) | github.com/mikebrady/shairport-sync | Several permissive licenses; see its `LICENSES` file | Yes |
| OpenSSL 1.0.2 (`libssl1.0.0:armhf`) | Ubuntu 16.04 archive | OpenSSL / SSLeay license | Yes |
| libconfig (`libconfig9:armhf`) | Ubuntu 16.04 archive | LGPL-2.1+ | Yes |
| popt (`libpopt0:armhf`) | Ubuntu 16.04 archive | MIT | Yes |
| GCC 4.9 ARM cross compiler, squashfs-tools and other build tools | Ubuntu 16.04 archive | GPL and others | No (build only) |

The license texts ship with each source: in the shairport-sync source tree,
and under `/usr/share/doc/<package>/copyright` in the build container.

Because built images contain Harman's firmware and third-party code, please
don't redistribute them; share this kit instead.
