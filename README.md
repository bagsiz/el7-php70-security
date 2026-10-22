# el7-php70-security

Patched PHP 7.0 RPMs for **CentOS 7** (Remi packages) fixing
**CVE-2026-109618** and **CVE-2026-109619** (GHSA-w8hw-w9fx-j79w, GHSA-6wmf-4rv5-p3rp).
The repo also includes an installer that finds the PHP installs on a server, upgrades
them and can roll the upgrade back.

> ⚠️ PHP 7.0 has been end-of-life since 2019 and upstream did not publish a fix for this
> branch. The CVE fix here is a **backport of the official PHP 7.4 patch**
> (`PHP-7.4-CVE-2026-109618-109619` in php-src) to 7.0. It is not an official patch.
> Test it on a non-production server first.

## Quick start

```bash
curl -fLO https://raw.githubusercontent.com/bagsiz/el7-php70-security/main/php70-cve.sh
chmod +x php70-cve.sh

./php70-cve.sh status      # list every PHP on the server and its patch status
./php70-cve.sh install     # upgrade installed PHP 7.0 packages (asks for confirmation; -y to skip)
./php70-cve.sh uninstall   # roll back to the previous versions
```

The RPMs are published as [release assets](https://github.com/bagsiz/el7-php70-security/releases/tag/v7.0.33-47.1).
`install` downloads the archive it needs and checks it against a SHA256 that is hardcoded
in the script. If the server has no internet access, download the archive by hand and put
it next to the script.

### Network timeouts

Network waits are capped at **10 seconds** so the script does not hang on unreachable
hosts. This matters on CentOS 7 servers, which are EOL and often still list dead mirrors
such as `mirrorlist.centos.org`.

| Step | Behaviour |
|---|---|
| Release download (`curl`) | Gives up if no connection is made within 10s, or if the download stalls (below 1 KB/s) for 10s. No retry. A slow download that is still moving is not cut off |
| `yum` / `yumdownloader` (backup, `rpmrebuild` install, install, rollback) | 10s per request, one retry (in yum, `0` would mean "retry forever"), and unreachable repositories are skipped (`skip_if_unavailable`) |

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `PHP70CVE_NET_TIMEOUT` | `10` | Network timeout in seconds, e.g. `PHP70CVE_NET_TIMEOUT=30 ./php70-cve.sh install` on a slow link |
| `PHP70CVE_RELEASE_URL` | this repo's `v7.0.33-47.1` release | Download the archives from a mirror or an internal server instead |

## What it detects

`status` and `install` start by listing every PHP they can find on the server:

- the `php`, `php70`, `php7.0`, `php-fpm` and `php-cgi` commands (symlinks are resolved)
- copies under `/usr/local` and `/opt`, and under `/opt/remi/php*`
- running `php-fpm` master processes
- PHP modules loaded by Apache (mod_php)

For each binary it looks up the RPM that owns it:

| Found | Action |
|---|---|
| `php`, `php-cli`, `php-fpm`, … **7.0.x** from Remi `remi-php70` (`/usr/bin/php`, `php-fpm` service, mod_php) | upgraded with `php70-rpms-base` |
| `php70-php-*` from Remi SCL (`/opt/remi/php70`, `php70-php-fpm` service) | upgraded with `php70-rpms-scl` |
| Both on one server | both are upgraded |
| Webtatic `php70w`, IUS `php70u`, Debian/Ubuntu `php7.0`, source builds, PHP other than 7.0 | reported only, not changed |

Example `status` output from a server with base PHP 7.0, mod_php and PECL extensions:

```
==> PHP on this server
  [patchable: base] /usr/bin/php  [PHP 7.0.33]  (command 'php')
  [patchable: base] /usr/sbin/php-fpm  [PHP 7.0.33]  (command 'php-fpm'; RUNNING: php-fpm master pid 192)
  [patchable: base] /usr/lib64/httpd/modules/libphp7.so  [PHP 7.0.33]  (Apache module (/etc/httpd/conf.modules.d/15-php.conf))
  [left as is     ] /usr/local/bin/php  [PHP 7.0.33]  (command 'php') : not owned by any package: built from source / copied by hand (not supported)
==> Installed packages: php (base, remi-php70)
  php                              7.0.33-21.el7.remi       UNPATCHED (patched build available)
  php-cli                          7.0.33-21.el7.remi       UNPATCHED (patched build available)
  php-common                       7.0.33-21.el7.remi       UNPATCHED (patched build available)
  php-pecl-redis5                  5.3.4-1.el7.remi.7.0     left as is (not shipped here)
  ...
==> Services
  php-fpm          active
  httpd            active
```

The script only replaces PHP packages that are already installed. It does not touch
packages that are not in the release, such as PECL extensions (`php-pecl-*`), `php-pear`
or `php70-runtime`. PECL extensions keep working because the PHP API/ABI is unchanged.

## What `install` does

1. Runs pre-flight checks: root, CentOS 7, x86_64, and `php-fpm -t` must already pass.
2. Downloads the RPM archive and verifies it against the pinned SHA256, then verifies
   each RPM against `SHA256SUMS`.
3. Saves a backup under `/var/lib/php70-cve-2026/<base|scl>/backup-<timestamp>/`:
   - the RPMs of the currently installed versions (see [Rollback backups](#rollback-backups))
   - the PHP configuration (`/etc/php.ini`, `/etc/php.d`, `/etc/php-fpm.d`, `/etc/opt/remi/php70`, …)
   - the list of services that were running
4. Upgrades the packages with `yum localinstall`.
5. Checks the result:
   - `php -v`
   - `php -m` must load without warnings
   - the changelog must contain the CVE
   - `php-fpm -t` and `apachectl -t` must pass
6. Restarts the services that were running (`php-fpm` / `php70-php-fpm`, `httpd`).
7. **Rolls back automatically** if any of these steps fails.

`uninstall` puts the backed-up RPMs back with `rpm -Uvh --oldpackage`, so the server
returns to exactly the versions it had. Configuration files are not restored
automatically; the backup path is printed.

### Rollback backups

yum does not keep the `.rpm` files of installed packages by default (`keepcache=0`), and
Remi's EL7 repositories only still carry the newest builds (`7.0.33-41` and `-42`). A
server running an older build, such as `7.0.33-21` or `7.0.23-1`, usually has that RPM
nowhere. Before upgrading, the script therefore looks for the RPM of each installed
version in this order:

| # | Source | Notes |
|---|---|---|
| 1 | **yum cache** (`/var/cache/yum`) | Present when `keepcache=1` or the package was downloaded earlier. The file must match the exact name-version-release and pass `rpm -K` |
| 2 | **repositories** (`yumdownloader`) | The exact version, if the repository still has it |
| 3 | **`rpmrebuild`** | Rebuilds the RPM from the RPM database and the installed files. The result is **unsigned** and not byte-identical to the original, and config files go in as they are on disk now. Files missing on disk (docs not installed, files deleted by hand) are left out. See [rpmrebuild on servers without repositories](#rpmrebuild-on-servers-without-repositories) |
| – | none of the above | The script warns and asks before continuing. `uninstall` then moves those packages to the newest version left in the repositories (Remi `7.0.33-42`, unpatched) |

#### rpmrebuild on servers without repositories

Old servers often cannot reach EPEL or the CentOS repositories, so `rpmrebuild` and
`rpm-build` cannot be installed from there. The release therefore also ships
`el7-rpmrebuild-tools.tar.gz`:

- `rpmrebuild-2.11-3.el7` from EPEL 7
- `rpm-build` for every `rpm` version CentOS 7 shipped, 13 in all from 7.0 to 7.9
  (`4.11.1-16` … `4.11.3-48.el7_9`). `rpm-build` only installs on the exact `rpm` version
  it was built for
- all packages are signed by CentOS 7 or EPEL 7 (`rpm -K` checked); the archive's SHA256
  is pinned in the script

When `rpmrebuild` is needed and not installed, the script uses these tools in this order:

1. It takes the `rpm-build` that matches the server's `rpm` and installs it together with
   `rpmrebuild` using `rpm -i --nodeps`. Rebuilding installed files needs neither perl,
   gdb nor `redhat-rpm-config`, which `rpm-build` would otherwise pull in.
2. It removes both packages again once the backup is done. Packages that were already
   installed are left alone.
3. Only if this fails does it try `yum install rpmrebuild`.

The rebuilt packages use SHA256 file digests and an xz payload, like the originals.

The source used for each package is printed during `install` and `uninstall`, and is
recorded in `sources.txt` inside the backup directory:

```
==> Creating backup: /var/lib/php70-cve-2026/base/backup-20261022-101500
  configuration: /var/lib/php70-cve-2026/base/backup-20261022-101500/config.tar.gz
  php-cli-7.0.33-21.el7.remi.x86_64                rebuild
  php-common-7.0.33-21.el7.remi.x86_64             rebuild
  ...
  RPMs of the current versions: 10/10 backed up
WARNING: some RPMs were rebuilt from the installed files with rpmrebuild (unsigned, not identical to the original)
```

## Package contents (`7.0.33-47.1.el7`)

- **base** (`php70-rpms-base.tar.gz`, `php-*`): built from Remi's `php-7.0.33-42` SRPM,
  which is what `remi-php70` servers run. On top of it are the security fixes Remi later
  added only to the SCL branch:
  - CVE-2024-8925, CVE-2024-8926, CVE-2024-8927, CVE-2024-8932
  - CVE-2024-11233, CVE-2024-11234, CVE-2024-11236
  - GHSA-4w77-75f9-2c8w
  - CVE-2026-6722, CVE-2026-6735, CVE-2026-7261, CVE-2026-7262, CVE-2026-7568
  - GH-22187

  The CVE-2026-109618/109619 backport is applied last. File lists, config files,
  scriptlets, provides and requires are identical to Remi's `7.0.33-42` packages; only the
  version strings differ. This includes the ZTS build and `libphp7-zts.so`.
- **scl** (`php70-rpms-scl.tar.gz`, `php70-php-*`): Remi's `php70-php-7.0.33-47` SRPM plus
  the CVE-2026-109618/109619 backport.

## Behaviour changes

These come from the upstream fix:

- A request that exceeds `memory_limit` (or hits another out-of-memory condition)
  terminates the worker process with `exit(1)` instead of unwinding. PHP-FPM starts a new
  worker. Shutdown functions and destructors do not run for that request.
- The out-of-memory fatal error goes to stderr, not to `error_log`. To see it in the
  PHP-FPM log, set `catch_workers_output = yes` in the pool configuration.
- `session.upload_progress` is disabled.

## FAQ

**Packages marked "left as is" (`php-pecl-*`, …): are they vulnerable, do they need updating?**
Not for these CVEs. CVE-2026-109618/109619 are in the PHP core: the Zend engine, request
startup and shutdown, multipart parsing and the session extension. Those are fixed by
upgrading `php-common`, `php-cli`, `php-fpm` and the other core packages. PECL extensions
are separate code that runs inside the patched core, so they don't need to change. They
can still have issues of their own. For example, `php-pecl-xdebug` should not be installed
on production servers.

**The script reports a PHP as "left as is" (not supported). What now?**
That PHP was not installed from Remi's packages: it may be a source build, Webtatic, IUS,
a Debian/Ubuntu package, or a version other than 7.0. It has to be patched or upgraded
some other way.

## Testing

Everything was tested in clean CentOS 7 containers against Remi's `7.0.33-42` packages:

- **Installer, 26 checks each for base and SCL:** install, re-install (no-op), uninstall,
  rollback when backup RPMs are missing, automatic rollback when verification fails, a
  tampered RPM or archive being refused, no PHP on the host, base and SCL on the same
  host, and an SCL install without the CLI package.
- **Rollback backups:** each source was tested on its own (yum cache only, `rpmrebuild`
  only, repositories) and returned the server to the exact previous version. After a
  rollback from `rpmrebuild` packages, `rpm -V` reports no changes.
- **Offline server:** the test ran with no yum repositories reachable and without
  `rpm-build`/`rpmrebuild` installed. The tools were fetched from the release and every
  package was backed up with `rpmrebuild`. The tools were removed afterwards, and the
  rollback returned the server to the exact previous version.
- **Bundled `rpm-build` on every CentOS 7 release:** tested on the official `centos:7.0.1406`
  … `centos:7.9.2009` images. On each one, the matching `rpm-build` was found and
  `rpmrebuild` rebuilt installed packages with the same file list and config files.
- **php-src test suite**, about 3,500 tests: Zend, basic, lang, session and string tests.
  The only differences from the unpatched packages are the expected ones: the
  `session.upload_progress` (`rfc1867*`) tests fail, and one out-of-memory message has
  cosmetic formatting changes. Upstream's own 7.4 patch shows the same differences.
- **Not covered:** real systemd and Apache. The containers used a stub `systemctl`. Run
  `status` and `install` on one server and check the output before rolling out further.

## Disclaimer

**USE AT YOUR OWN RISK.** This project, including the installer script, the patches and
the RPM packages, is provided **"AS IS", WITHOUT WARRANTY OF ANY KIND**, express or implied.
This includes, without limitation, warranties of merchantability, fitness for a particular
purpose, security and non-infringement.

- **Not official.** The packages are unofficial rebuilds. The CVE-2026-109618/109619 fix
  for PHP 7.0 is an unofficial backport that has not been reviewed or approved by the PHP
  project. It may be incomplete, may not fully fix the vulnerabilities, and may introduce
  bugs or other security issues.
- **Your responsibility.** You decide whether to use this software, and you are
  responsible for testing it, for backing up your systems and data, and for any change you
  make to your servers. Running unsupported software (CentOS 7, PHP 7.0) carries risk that
  no patch removes. The recommended long-term fix is to move to a supported operating
  system and PHP version.
- **No liability.** In no event shall the authors or contributors be liable for any claim,
  damages or other liability arising from, out of, or in connection with this software or
  its use. This covers direct, indirect, incidental, special, consequential or punitive
  damages, data loss, downtime and security incidents, whether in contract, tort or
  otherwise, even if advised of the possibility of such damage.
- **No support obligation.** There is no commitment to support, maintenance, updates or
  security fixes.
- **Not security advice.** Nothing in this repository is professional, security or legal
  advice.
- **No affiliation.** This project is not affiliated with, endorsed by or sponsored by:
  - The PHP Group or the PHP project
  - Remi Collet / remirepo
  - Red Hat, Inc. or the CentOS Project
  - GitHub, Inc.

  "PHP", "CentOS", "Red Hat" and other names are trademarks of their respective owners
  and are used here only to describe compatibility.

## License

- **Installer script and documentation** (`php70-cve.sh`, `README.md`): MIT License, see
  [`LICENSE`](LICENSE).
- **RPM packages (release assets):** these contain third-party software that stays under
  its original license:
  - PHP is under the [PHP License v3.01](https://www.php.net/license/3_01.txt). The PHP
    patches, including the CVE backport, are derived from php-src and fall under the same
    license.
  - Zend Engine is under the Zend Engine License v2.00.
  - Bundled libraries and extensions are under their own licenses.
  - The RPM spec files and packaging come from Remi's repository under the MIT License.

  License texts are included in the packages: `/usr/share/licenses/php-common-7.0.33/`
  for base, `/opt/remi/php70/root/usr/share/licenses/php70-php-common-7.0.33/` for SCL.

This product includes PHP software, freely available from <http://www.php.net/software/>.
