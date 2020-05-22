Build a Gentoo Base System in a Container
=========================================

Run `./gentoo-base.docker` to fetch the latest Gentoo stage3 image and use this
as a basis to build a new `@system` image intended to act as the base on which
to build further binary packages. *Be warned that this process may take several
hours even with all dependent packages pre-built as binaries*.

`./gentoo-build-pkg.docker <package>` will then use the resulting image to
build the specified package and store the result persistently on the host as a
binary package.

The mount-points onto the host are defined in `common/run.sh`, and may need to
be customised for your local setup.

_Currently, the system assumes that srcshelton/gentoo-ebuilds is available as
a repository overlay_

Docker Images
=============

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
 * @system deployment relocated to the container root, ready to be used as the
   build environment to create new binary packages.

