# image used for the healthcheck binary
FROM golang:1.26-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS gobuilder
WORKDIR /src
COPY healthcheck/ ./
# Static, so it runs in an image that has no loader guarantee of its own.
RUN CGO_ENABLED=0 go build -trimpath -ldflags '-w -s' -o /healthcheck .

#
# ---
#

# image used to copy our official nginx binaries
FROM nginx:1.31.4@sha256:b34848eff6db786b6b1282d3a9c3fd0b5563dfb6d261df4923378b419e0d24f0 AS base

# Fail the whole pipeline on the first failure. Without this the `ldd | awk |
# while read` below reports success even when ldd finds nothing, and the image
# is built missing every library it was supposed to carry.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Patch the packages before lifting the libraries out. Whatever ships in the
# upstream image is what gets copied, and upstream rebuilds its image on its own
# schedule rather than on the security team's — so without this the hardened
# image inherits every unpatched library the upstream tag happens to carry.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# create empty index page
RUN echo 'Hello world' > /index.html

# Copy nginx and everything it needs into /opt, preserving paths.
#
# The library list is resolved with ldd rather than written out. Upstream named
# /lib/x86_64-linux-gnu/... paths directly, which meant the image could only
# ever be built for amd64 — on arm64 every one of those cp calls fails. It also
# meant the list silently rotted every time nginx picked up or dropped a
# dependency.
#
# The /lib -> /usr/lib rewrite is what makes the result copyable into
# distroless: Debian is usr-merged, ldd reports the /lib path, and `cp
# --parents` then materialises /opt/lib as a real directory. Copying that over
# distroless's /lib, which is a symlink, fails with "cannot copy to
# non-directory" and names an overlay path rather than the file at fault.
#
# The readlink pass copies the soname symlink and the file it points at. cp -a
# alone preserves the link and leaves the target behind, so nginx starts
# looking for a library that is not there.
RUN rm -r /opt && mkdir /opt \
    && cp -a --parents /usr/sbin/nginx /opt \
    && cp -a --parents /usr/lib/nginx /opt \
    && cp -a --parents /usr/share/nginx /opt \
    && cp -a --parents /var/cache/nginx /opt \
    && cp -a --parents /var/log/nginx /opt \
    && { ldd /usr/sbin/nginx; find /usr/lib/nginx/modules -name '*.so' -exec ldd {} + 2>/dev/null; } \
       | tr -s ' ' | grep '=> /' | awk '{print $3}' \
       | sed -e 's|^/lib/|/usr/lib/|' -e 's|^/lib64/|/usr/lib64/|' \
       | sort -u \
       | while read -r lib; do \
           cp -a --parents "$lib" /opt; \
           target="$(readlink -f "$lib")"; \
           [ "$target" != "$lib" ] && cp -a --parents "$target" /opt; \
           true; \
         done

#
# ---
#

# Distroless, matched to the Debian release the nginx image is built on. nginx
# is copied out of that image as a dynamically linked binary, so a mismatched
# glibc here is a container that exits before it logs anything.
FROM gcr.io/distroless/base-debian13:nonroot@sha256:d199d20fb09c898d8822ae5cbd5cf3c6d424e9b5e1fc2eb9a719a7752cd9d861

# image owner label
LABEL org.opencontainers.image.source="https://github.com/irondragonservices/iron-nginx"

# copy our empty index page
COPY --from=base --chown=nonroot /index.html /assets/index.html

# copy in our healthcheck binary
COPY --from=gobuilder --chown=nonroot /healthcheck /healthcheck

# copy in nginx and its libraries. Not chowned to nonroot: these are system
# files and the runtime user has no business owning them.
COPY --from=base /opt /

# nginx writes its cache and logs as the runtime user
COPY --from=base --chown=nonroot /var/cache/nginx /var/cache/nginx

# copy our config files
COPY --chown=nonroot mime.types nginx.conf /

# run as an unprivileged user
USER nonroot

# default nginx port
EXPOSE 8080

# healthcheck to report the container status
HEALTHCHECK --interval=5s --timeout=10s --retries=3 CMD [ "/healthcheck", "8080" ]

# entrypoint
CMD ["/usr/sbin/nginx", "-p", "/tmp/", "-e", "/dev/stderr", "-c", "/nginx.conf"]
