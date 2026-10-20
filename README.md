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

Minimum supported versions are Apple `container` 1.4.1, Podman 3.4.4 on Linux
(4.0.3 for the host-mounted macOS `podman machine` workflow), and Docker
18.06.0 with client and server API 1.38.  If Podman uses `crun` as its active
OCI runtime, `crun` 1.0.0 or later is also required.

Apple `container` 1.4.1 is both the minimum accepted release and the last
runtime-validation point.  It contains
[additional upstream security fixes](https://github.com/apple/container/releases/tag/1.4.1).
The integration handles the nested system-status `paths` object introduced by
1.4.1.  The [1.5.0 changes](https://github.com/apple/container/compare/1.4.1...1.5.0)
have been source-audited: the build, export, lifecycle and cleanup commands,
resource options, and JSON fields used here remain compatible.  No script
changes or higher minimum version are required.  The helper still warns about
versions newer than 1.4.1 because source review and fixture tests do not replace
a live build with the newer release.

Upgrading to [1.5.0](https://github.com/apple/container/releases/tag/1.5.0)
provides improvements without additional flags:

- Build contexts beneath symlinked directories no longer lose directory
  contents.  This is relevant to snapshot builds under macOS temporary paths.
- Empty image entrypoints are handled correctly, and socket-forwarding
  connections are cleaned up when clients disconnect.
- The bundled Containerization update fixes
  [hard-link handling during image unpacking](https://github.com/apple/containerization/pull/928),
  [oversized blob downloads](https://github.com/apple/containerization/pull/932),
  [zstd temporary-disk consumption](https://github.com/apple/containerization/pull/931),
  [corrupt-layer hangs](https://github.com/apple/containerization/pull/927), and
  [socket-forwarding/exec stalls](https://github.com/apple/containerization/pull/933).
  The disk-saving benefit of streaming zstd decompression applies to images
  with zstd layers; no compression change is needed for our exported tar files.

After upgrading, plan a service restart using
`./tools/apple-container.sh --restart` so subsequent containers use the updated
runtime.  This interrupts running workloads; `--reset` is not required.  An
explicitly configured older `vminit.image` overrides the new default and needs
separate review.

The removed experimental `k8s start` command is not used here.  In 1.5.0 there
is no `commit` command; see the 1.6.0 qualification below.  Containerization
filesystem statistics and runc/seccomp support are not exposed through these
releases' `container` CLI.  Builder CPU/memory options and VM resource overhead
remain unchanged; the updates do not justify reducing existing allocations.

### Apple Container 1.6.0

The [1.6.0 source changes](https://github.com/apple/container/compare/1.5.0...1.6.0)
have been reviewed against the commands and JSON fields used here.  The minimum
remains 1.4.1, and 1.6.0 is covered by version-acceptance fixtures, not a live
1.6.0 build.  The helper's runtime-validation marker therefore remains 1.4.1.

- `build` and `builder` are now CLI plugins, but their command names and options
  remain compatible.  Install the complete distribution, including both
  plugins, rather than copying only the `container` executable.  Plugin
  discovery needs running system services, so a failed `builder --help` while
  the system is stopped is not evidence of a missing installation.  The helper
  places debug flags after the builder subcommand so they reach the plugin;
  non-empty `CONTAINER_DEBUG` is also forwarded as an explicit flag.
- Native [`container commit`](https://github.com/apple/container/blob/1.6.0/Sources/ContainerCommands/Container/ContainerCommit.swift)
  is available, but is not a drop-in snapshot replacement.  Its
  [image metadata](https://github.com/apple/container/blob/1.6.0/Sources/ContainerCommands/Image/OCIImageArchive.swift)
  preserves the container's effective executable, arguments, environment, user
  and working directory, with no Docker-style `--change` overrides.  Our helper
  deliberately copies parent-image environment, resets root variables and the
  entrypoint/command, and records new provenance labels.  Keep export/rebuild
  snapshots until native commit can preserve that contract.  Native commit
  also exports the whole rootfs into one layer; it is not an incremental-layer
  or copy-on-write optimisation.
- Build-context `read`/`info` now reject absolute-target symlinks, even when the
  target is inside the context.  Relative links confined to the context remain
  valid; normal `walk` transfers are unchanged.  Tracked build inputs contain
  no symlinks, but locally added links should be checked if a build fails.
- `image list` can return valid partial JSON **and a non-zero status** when an
  image record is unreadable.  Our checked JSON paths still fail closed rather
  than mistaking that partial list for a complete inventory.  Repair the image
  store instead of suppressing this status.
- DNS aliases, including subtree aliases, can be set with repeatable
  `alias=NAME` properties on `--network`.  These may help service deployments;
  they are not needed for package builds.  Use Apple's network syntax explicitly
  on 1.6.0 or later; Docker's `--network-alias` is not translated here.

Upgrading also fixes sandboxed `system status` false negatives, sparse OCI
image imports, and missing/initially empty container logs.  Builder shim
0.13.2 and Containerization 0.52.1 are selected by the new upstream defaults.
The runtime update fixes registry authentication without a `service` challenge
parameter, verifies registry content digests, and corrects EXT4 image layout
edge cases.  These improvements need no new flags.  Cloud Hypervisor direct-I/O
and virtiofsd tuning additions are not applicable to this macOS Virtualization
backend, and the new detailed library network statistics are not exposed by
the CLI's statistics payload.

## Continuous integration

The `Validate Gentoo container builds` workflow probes the Docker path on the
native GitHub-hosted amd64 and arm64 Linux runners for relevant pushes and pull
requests.  A monthly schedule and manual dispatch build and validate the full
`gentoo-build` image on both architectures.  Portage binary packages are kept
in generational workflow caches to accelerate later builds.  A restored
generation is mounted read-only as a Portage binary host while the build writes
to a fresh directory.  Only binaries actually selected from the old generation,
plus packages built during the run, enter the next generation; unrelated stale
packages are therefore not carried forward indefinitely.  Manual runs can
independently disable cache restore and cache save: disable both for an isolated
no-binary-package-cache diagnostic run, or disable restore alone to seed a fresh
cache.

Cache keys and optional artifact names contain a generation-affinity label from
`./gentoo-init.docker --print-pkgdir-cache-affinity`.  Its readable portion
identifies Linux, Gentoo architecture, `CHOST`, full profile, compiler family,
and target CPU.  The digest also covers normalized `CPU_FLAGS_ARM` or
`CPU_FLAGS_X86` and the exact compiler and Rust targets.  The complete record is
shown in the workflow summary.  Exact affinity matches select a useful
immutable CI generation; they are deliberately stricter than the safety check
for a long-lived writable package directory.

The writable `PKGDIR` remains organised as architecture, `GENTOO_PKGHOST`, and
profile version.  `GENTOO_PKGHOST` is the sharing boundary: machines using the
same deterministic compiler target can use one value, while heterogeneous
systems can select CPU-class values such as `cortex-a72`.  Its `.metadata`
records architecture, `CHOST`, compiler family, target CPU, and exact default C
and Rust target options.  These are a universal compatibility boundary because
Portage does not compare `CFLAGS` when selecting packages.  Portage separately
verifies USE and dependency compatibility with `--binpkg-respect-use=y` and
`--binpkg-changed-deps=y`; `CPU_FLAGS_*` participate through USE expansion and
therefore belong to CI affinity rather than the metadata rejection boundary.
Legacy metadata containing the same architecture and deterministic CPU is
upgraded in place without removing cached packages.  A genuine mismatch should
use another `GENTOO_PKGHOST`/`PKGDIR`, or move aside only the reported cache
subtree; the shared parent cache need not be deleted.
Deliberate `GENTOO_BUILD_*` experiments remain caller-managed and should use an
isolated `GENTOO_PKGHOST` or disable cache restore and save.

Recognised processors use explicit named compiler targets.  An unknown CPU, or
a virtual CPU whose exposed features do not satisfy its reported model, uses a
deterministic architecture baseline instead.  No image-build fallback uses
`-march=native`, `-mcpu=native`, or Rust `target-cpu=native`; this keeps shared
package directories and distributed compiler workers independent of whichever
machine happens to execute the compiler.

CI preserves the warning for an unknown or feature-masked CPU.  Only after that
warning is detected does it collect `lscpu` and `/proc/cpuinfo` details and, if
needed, download, verify, and build a pinned `cpuid2cpuflags` release.  Known
usable CPUs therefore incur no diagnostic download or compilation cost.

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
These deliberate overrides are not incorporated into persistent package-cache
metadata or CI generation affinity; callers using experimental flags should
disable cache reuse or choose a separate `GENTOO_PKGHOST` value for that run.

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

  With 1.4.1 or later, `./tools/apple-container.sh --clean` reclaims unused
  space from the root filesystem and writable named volumes of every running
  container.  It does not remove containers, images, or volumes, and does not
  stop the container system.

  Startup and automatic engine selection check service/builder status, not
  network connectivity.  A successful restart does not establish that guest
  DNS, outbound connections, or published ports work.

  To diagnose an **existing running container**, use its name and, optionally,
  a TCP port on which its service should listen:

  ```sh
  ./tools/apple-container.sh --diagnose my-container --port 8080
  ```

  This reports host routes for each attached IPv4 address, host-to-container
  TCP connections, guest exec availability, guest-loopback TCP, guest DNS,
  and host/guest outbound TCP separately.  The service port is the port
  **inside the container**, not a published host port.  A service bound only
  to a specific address may intentionally fail either the loopback or direct
  address check.  TCP success establishes a connection, not application health.
  IPv6 and the separate builder VM are not tested.

  For an HTTP(S) service, optionally test its published host endpoint too:

  ```sh
  ./tools/apple-container.sh --diagnose my-container --port 8080 \
    --published-url http://127.0.0.1:18080/health
  ```

  Supply a health URL served by that container's published port (18080 in
  this example, mapped to container port 8080).  This host `curl` GET must
  complete with a 2xx response within the probe timeout; redirects and other
  HTTP statuses fail.  The response body is discarded without content checks.
  Proxy environment variables and curl configuration files are ignored, and
  HTTPS certificates are verified normally.  This tests the supplied endpoint;
  it does not automatically verify which container owns it.  Without this
  option, published-port forwarding remains untested and does not affect the
  diagnostic exit status.

  Each command is bounded by `--probe-timeout SECONDS` (default 10; range
  2–300).  The default DNS name is `distfiles.gentoo.org`; the outbound probe
  opens TCP connections to `1.1.1.1:443` independently of DNS.  Override these
  with `--probe-dns NAME --probe-address IPV4 --probe-port PORT` to use endpoints
  appropriate to your network.  Host `jq`, `route`, `ifconfig` and `nc` are
  required; guest probes use `/bin/sh` and Python 3.  Missing guest tools or an
  omitted `--port` produce incomplete results.  Exit codes are 0 for passed
  checks, 1 for a failure, and 2 for incomplete checks without a failure.
  Nothing is installed, restarted, or reconfigured.  On timeout the local
  probe process is killed; guest Python probes also have their own deadlines.
  Name resolution uses the guest resolver, including hosts files and caches;
  success does not necessarily mean that a new DNS query reached a server.

  [Upstream issue #1881](https://github.com/apple/container/issues/1881)
  describes VPN-related host routing and guest outbound failures.  A
  [report using 1.4.1](https://github.com/apple/container/issues/1881#issuecomment-5748086051)
  also describes a stale tunnel despite Tailscale reporting itself stopped,
  and failures persisting after the host route was corrected.  Inspect the
  actual route/interface and connectivity results rather than relying on VPN
  status or DNS success alone.  A hung guest exec does not by itself establish
  a guest networking fault.

  [1.5.0 fixes egress loss after localhost DNS changes](https://github.com/apple/container/pull/2256)
  by updating only Container's PF anchor instead of reloading the host's entire
  ruleset.  That fix addresses a specific DNS-management failure, not all
  VPN-related failures described above; the diagnostic and recovery guidance
  remains applicable.

  A [further 1.4.1 report](https://github.com/apple/container/issues/1881#issuecomment-5749912618)
  found that connecting NordVPN broke published-port access and guest internet
  access even with correct host routing and working guest loopback.  In that
  setup, Azure VPN alone worked, and disconnecting NordVPN immediately restored
  connectivity without a restart.  These are reported observations, not a
  confirmed diagnosis of the underlying cause or a claim that all VPNs fail.

  Capture diagnostics, resolve or disconnect the interfering VPN/tunnel, then
  **retest connectivity before restarting anything**.  If failures persist,
  running the helper with `--restart` is a possible recovery step: an
  [earlier report](https://github.com/apple/container/issues/1881#issuecomment-4879992099)
  recovered guest outbound connectivity after disabling the exit node and
  restarting the system.  Recovery is not guaranteed; the stale-tunnel report
  did not test that restart in isolation.  Capture diagnostic results before
  restarting, which interrupts running workloads.  `--clean` only reclaims
  storage; `--reset` deletes persistent data and is not a demonstrated fix
  for this networking issue.

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
