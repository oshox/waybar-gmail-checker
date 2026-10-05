# Builds waybar-gmail + waybar-gmail-popup against Fedora 44 and publishes
# them as a FROM scratch image holding only the two binaries, so another
# image (the bootc image in oshox/laptop-setup) can import them with:
#
#   COPY --from=ghcr.io/oshox/waybar-gmail-checker:latest \
#       /usr/bin/waybar-gmail /usr/bin/waybar-gmail-popup /usr/bin/
#
# Why Fedora 44 and not the CI runner's own toolchain: waybar-gmail is fully
# static (musl), but waybar-gmail-popup links the system GTK3 and
# gtk-layer-shell, so it has to be built against the same Fedora release as
# the image that will run it.
#
# Build locally:  podman build -t waybar-gmail-checker:local .
# See .github/workflows/build.yml for how CI builds and pushes it.

FROM quay.io/fedora/fedora:44 AS build

# Pinned to 0.16.*: Fedora 44's repos carry both zig 0.15.2 and 0.16.0, and
# this project needs 0.16. libsecret/gnome-keyring/dbus-daemon are only here
# for `zig build test` (see below), not for the build itself.
RUN dnf -y install \
        'zig-0.16.*' gtk3-devel gtk-layer-shell-devel pkgconf-pkg-config \
        libsecret gnome-keyring dbus-daemon \
    && dnf clean all \
    && zig version

# Everything below runs as an unprivileged user: the throwaway keyring used by
# the tests (gnome-keyring-daemon) aborts at startup as root in a container.
RUN useradd -m builder && mkdir /src && chown builder /src
WORKDIR /src
COPY --chown=builder . .
USER builder

RUN zig build -Doptimize=ReleaseSmall

# The tests in src/secrets.zig call the real `secret-tool`, which needs a
# Secret Service on a session bus; ci/test.sh sets up a throwaway one (see its
# header). Tests run in the build so a failing test fails the image build and
# nothing is published.
RUN ./ci/test.sh --summary all

FROM scratch
LABEL org.opencontainers.image.source="https://github.com/oshox/waybar-gmail-checker" \
      org.opencontainers.image.description="waybar-gmail and waybar-gmail-popup binaries (Fedora 44, x86_64), for COPY --from= into other images"
# root-owned: COPY --from= in the importing image preserves ownership, and the
# build stage's files belong to the unprivileged `builder` user (uid 1000),
# which must not end up owning files in another image's /usr/bin.
COPY --from=build --chown=0:0 /src/zig-out/bin/waybar-gmail /src/zig-out/bin/waybar-gmail-popup /usr/bin/
