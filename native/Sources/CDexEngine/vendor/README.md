# Third-party code in the replacement engine

Vendored unmodified, except for files left out as listed. Licences are kept beside the code and
must ship with any build that links it. Check here before adding or updating anything.

| Code | Version | Licence | Where |
| --- | --- | --- | --- |
| [Bungee Basic](https://github.com/bungee-audio-stretch/bungee) | 2.4.39 (`61f52bf`) | MPL-2.0 | `../../CBungee/` (command line tool and `Stream.h`, `Push.h`, `CommandLine.h` left out) |
| [PFFFT](https://bitbucket.org/jpommier/pffft) | v1.0.0 (`02fe771`) | BSD-style (FFTPACK) | `../../CBungee/vendor/pffft/` (its licence is at the top of `pffft.c` and `fftpack.c`) |
| [Eigen](https://gitlab.com/libeigen/eigen), `Core` only | `c29c800` | MPL-2.0 | `../../CBungee/vendor/eigen/` |

- Bungee's own files, and Eigen's, stay under MPL-2.0: changes to those files must be published.
  Keep Dex's code out of them, and keep them unmodified.
- Eigen is built with `EIGEN_MPL2_ONLY`, and only its `Core` is here. The one LGPL-derived file in
  Eigen (`IncompleteLUT.h`) isn't in the repo at all.
- Bungee **Pro** is a paid product and is not used: only `Bungee::Basic`.
- Nothing here is GPL, and nothing here came from a GPL DJ engine. See `docs/ENGINE-REBUILD-SPEC.md`.
