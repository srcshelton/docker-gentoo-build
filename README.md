# Build a Gentoo Base System in a Container

Run `./gentoo-init.docker` to fetch the latest Gentoo stage3 image and use this
to construct a new `@system` image, intended to act as the base upon which to
build further binary packages.

**Be warned that this process may take several hours even with all dependent
packages pre-built as binaries**.

`./gentoo-build-pkg.docker <package...>` will then use the resulting image to
build the specified package(s) and store them persistently on the host as
(by default) `.gpkg.tar` binary packages.

Gentoo's Portage allows many configuration files beneath `/etc/portage/` to be
represented as a single file, or as multiple files within a directory of the
same name.  Due to the need to merge elements from the host and elements from
the build-system, the container build process requires some of these
configuration elements to be stored in directories.  If changes need to be made
on the host system then the build process will advise of the fix required.

The file `gentoo-base/etc/portage/package.use.build/05_host.use` may be used to
include any host-specific configuration conventionally located in
`/etc/portage/make.conf` whilst `01_package.use.local` can used for build-image
overrides such as hardware- or architecture- specific customisations.

Please note: Certain elements may not work as intended if the overlay-repo
[srcshelton](https://github.com/srcshelton/gentoo-ebuilds) is not available on
the host system performing the container build - any configuration without this
overlay present is largely untested.  This overlay will be automatically
downloaded for non-Gentoo hosts.

**N.B. This build system can be hosted by either `podman` or `docker`, or by
Apple `container` on supported Apple Silicon macOS systems.  Set
`CONTAINER_ENGINE` to `auto`, `container`, `podman`, `docker`, or the full path
of a specific executable.**

If `CONTAINER_ENGINE` is unset or set to `auto` then operational engines are
preferred in the order `container`, `podman`, `docker` on macOS and `podman`,
`docker` on Linux.  A lower-priority engine may be selected by "auto" when it
has a more complete configured Gentoo image pipeline; completeness takes
precedence over the creation timestamps of a partial pipeline.

Minimum supported versions are Apple `container` 1.3.0, Podman 3.4.4 on Linux
(4.0.3 for the host-mounted macOS `podman machine` workflow), and Docker
18.06.0 with client and server API 1.38.  If Podman uses `crun` as its active
OCI runtime, `crun` 1.0.0 or later is also required.

## Continuous integration

The `Validate Gentoo container builds` workflow probes the Docker path on the
native GitHub-hosted amd64 and arm64 Linux runners for relevant pushes and pull
requests.  A monthly schedule and manual dispatch build and validate the full
`gentoo-build` image on both architectures.  Portage binary packages are kept
in the workflow cache to accelerate later builds.  Manual runs can independently
disable cache restore and cache save: disable both for an isolated no-binary-
package-cache diagnostic run, or disable restore alone to seed a fresh cache.

A manual dispatch can also upload one-day compressed image and `PKGDIR`
artifacts.  These are disabled by default because two architectures of images,
and especially the binary-package directories, can exceed the account's
[Actions artifact-storage allowance](https://docs.github.com/en/billing/concepts/product-billing/github-actions#free-use-of-github-actions).

The public `ubuntu-24.04-arm` runner is Linux/arm64, not macOS, so it cannot run
Apple `container`.  GitHub's hosted arm64 macOS runners do not support nested
virtualisation, while Apple `container` runs each container as a lightweight
Linux virtual machine.  Testing that engine therefore requires a bare-metal
self-hosted Apple Silicon runner; the hosted arm64 job exercises the shared
build pipeline through native Docker instead.

Set `VERBOSE` to a non-empty value to report engine selection and every
container-engine command.  Set `TRACE` to a non-empty value to enable shell
execution tracing.

On Linux hosts, ordinary compiler variables such as `CFLAGS`, `CXXFLAGS`, and
`RUSTFLAGS` retain their normal Portage meaning.  The explicit
`GENTOO_BUILD_<FLAG>` form overrides the corresponding value on both Gentoo and
non-Gentoo Linux hosts.  On macOS, ambient compiler variables commonly describe
Apple's compiler rather than the Linux target and are therefore reported and
ignored.  Use `GENTOO_BUILD_<FLAG>` to preserve one deliberate value, or
`GENTOO_USE_HOST_COMPILER_FLAGS=1` to preserve all unprefixed compiler variables.

(If upgrading from a packaged release of `podman` to a more current binary when
the original has already been executed at least once, it may be necessary to
remove the file `/dev/shm/libpod_lock` and then run `podman system renumber`)

## Getting started

In an environment which requires a Linux VM to host containers (e.g. macOS,
etc):

```sh
cp common/local.sh . && cp gentoo-base/etc/portage/make.conf .
eval "${EDITOR} local.sh make.conf"
```

... then use one of the following paths.

- For Apple `container`:

  ```sh
  ./tools/apple-container.sh --start
  CONTAINER_ENGINE=container ./gentoo-init.docker
  ```

- For `podman` or Podman Desktop:

  ```sh
  ./tools/podman-machine-setup.sh --init
  ```

- For Docker, start Docker Desktop and run:

  ```sh
  CONTAINER_ENGINE=docker ./gentoo-init.docker
  ```

- On a host running a non-Gentoo Linux distribution:

  ```sh
  cp common/local.sh . && eval "${EDITOR} local.sh"
  ./tools/host-init.sh
  sudo ./gentoo-init.docker
  ```

- On Gentoo Linux:

  ```sh
  eval "${EDITOR} common/local.sh"
  sudo ./tools/sync-portage.sh
  sudo dispatch-conf
  sudo ./gentoo-init.docker
  ```

## Container Images

- `gentoo-env`

   Empty stage with global environment variables set;

- `gentoo-stage3`

   Latest Gentoo `stage3` image, copied on top of `env` image to preserve
   environment;

- `gentoo-init`

   `gentoo-stage3`, with additional filesystem setup and entrypoint which will
   install `@system` to a separate build-root when the container is invoked;

- `gentoo-base`

   Intermediate `stage3` with with a new `@system` installed to a dedicated
   build-root, committed by running `gentoo-init` rather than built from a
   Containerfile file;

- `gentoo-build`

   `@system` deployment relocated to the container root, ready to be used as
   the build environment to create new binary packages.

<!-- vi: set colorcolumn=80: -->
