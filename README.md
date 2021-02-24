# Build a Gentoo Base System in a Container

Run `./gentoo-init.docker` to fetch the latest Gentoo stage3 image and use this
as a basis to build a new `@system` image intended to act as the base on which
to build further binary packages.
**Be warned that this process may take several hours even with all dependent
packages pre-built as binaries**.

`./gentoo-build-pkg.docker <package>` will then use the resulting image to
build the specified package and store the result persistently on the host as a
binary package.

Gentoo's Portage allows many configuration files beneath `/etc/portage` to be
represented as a single file, or as multiple files within a directory of the
same name.  Due to the need to merge elements from the host and elements from
the build-system, the container build process requires some of these
configuration elements to be represented as directories.  If this is required
but not the case on the host system, the build process will advise of the fix
required.

The file `gentoo-base/etc/portage/package.use.build/package.use.local` may be
used to represent any host-specific configuration conventionally located in
`/etc/portage/make.conf`.

Please note: Certain elements may not work as intended if the overlay-repo
[srcshelton](https://github.com/srcshelton/gentoo-ebuilds) is not available on
the system performing the container build - this configuration is largely
untested.

## Docker Images

`gentoo-env`
 * Empty stage with global environment variables set;

`gentoo-stage3`
 * Latest Gentoo stage3 image, copied on top of `env` image to preserve
   environment;

`gentoo-init`
 * gentoo-stage3, with additional filesystem setup and entrypoint which will
   install @system to a separate build-root when the container is invoked;

`gentoo-base`
 * Intermediate stage3 with with a new @system installed to a build-root,
   committed by running `gentoo-init` rather than built from a docker
   Dockerfile file;

`gentoo-build`
 * `@system` deployment relocated to the container root, ready to be used as
   the build environment to create new binary packages.

<!-- vi: set colorcolumn=80: -->
