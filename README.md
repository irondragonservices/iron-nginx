# irondragonservices/iron-nginx

Hardened nginx image for serving static content.

Forked from [ironpeakservices/iron-nginx](https://github.com/ironpeakservices/iron-nginx).

The official nginx binary and the libraries it needs, lifted into a distroless
base: no shell, no package manager, no coreutils. Runs as `nonroot`, listens on
8080, serves `/assets`.

```sh
docker pull ghcr.io/irondragonservices/iron-nginx:1.30
```

The tag tracks the nginx release, so `:1.30.4` is iron-nginx built on
`nginx:1.30.4`.

## Using it

```dockerfile
FROM ghcr.io/irondragonservices/iron-nginx:1
COPY --chown=nonroot ./public /assets
```

That is the whole integration for static content. To change nginx's behaviour,
replace the config:

```dockerfile
COPY --chown=nonroot nginx.conf /nginx.conf
```

There is no shell in the image, so `docker exec` and `RUN` in a derived stage
will not work. Build your assets in an earlier stage and `COPY --from` them.

## What is in it

- nginx and its shared libraries, resolved from the official image
- a static healthcheck binary, wired into `HEALTHCHECK`
- `/mime.types` and `/nginx.conf`
- `/assets/index.html`, so a bare `docker run` serves something

`/_health` exposes `stub_status` bound to localhost only; it answers 403 from
anywhere else, which is what the container healthcheck relies on.

Everything nginx writes goes under `/tmp` — pid file, caches, buffers — so the
filesystem can be mounted read-only.

## Verifying what you pulled

```sh
cosign verify ghcr.io/irondragonservices/iron-nginx:1 \
  --certificate-identity-regexp '^https://github.com/irondragonservices/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Changes from upstream

- **The image could only ever build for amd64.** The library list was written
  out by hand as `/lib/x86_64-linux-gnu/...` paths, so every `cp` fails on
  arm64. It is resolved with `ldd` now, which also stops the list rotting every
  time nginx picks up or drops a dependency.
- **Loadable module dependencies were not copied**, only the ones the main
  binary links against.
- **A soname symlink was copied without its target.** `cp -a` preserves the
  link and leaves the file behind, so nginx would start looking for a library
  that is not there.
- **Base moved from `distroless/base-debian10` to `base-debian13`.** Debian 10
  went end of life in 2024, and the nginx image is built on Debian 13 — a
  mismatched glibc is a container that exits before it logs anything.
- **nginx bumped from 1.25.4 to 1.30.4**, Go from 1.17.5 to 1.25.
- **The healthcheck now builds as a module.** It was built with
  `GO111MODULE=auto` out of `/go/src`, which stopped working in Go 1.22.
- `LABEL key value` replaced with `LABEL key="value"`.
- CI rebuilt as callers into
  [irondragonservices/.github](https://github.com/irondragonservices/.github).
  Upstream's publish workflow had no release step and used a personal account's
  credentials.

Verified on build: serves 200 on 8080, `/_health` answers 403 from outside the
container, and the container healthcheck reaches `healthy`.
