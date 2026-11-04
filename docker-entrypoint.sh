#!/bin/sh
# Entrypoint wrapper: optionally remap the container's internal user to a
# host UID/GID before exec'ing the real command, so files written under
# /root (profiles, downloads, camoufox cache) land on a host bind mount
# with an owner the host user can actually read/write/delete -- without
# this, the container always runs as root (no USER in the Dockerfile) and
# every file it creates on a host volume comes out owned by root:root,
# unreadable/undeletable by a non-root host user without sudo.
#
# Mirrors the approach already used by the sibling hermes-agent image
# (HERMES_UID/HERMES_GID + usermod/groupmod, see its docker-compose.yml),
# but without that image's s6-overlay init system -- this is a plain sh
# wrapper in front of tini, since tini has no init-hook mechanism of its
# own.
#
# Why remap the existing `node` user instead of creating a new one: the
# base node:*-trixie-slim image already ships a `node` user at uid/gid
# 1000, and useradd fails with "UID is not unique" if the requested
# CAMOFOX_UID happens to be 1000 (the common case -- most single-user
# Linux hosts have their first real user at uid 1000). Renaming/remapping
# the existing user via usermod/groupmod works for ANY uid, including 1000.
#
# Why HOME stays /root instead of switching to /home/node: every bind
# mount in every compose file (profiles, downloads) and the pre-baked
# Camoufox binary from the Dockerfile's build step live under /root/...
# Moving HOME would silently orphan both -- the running process would
# read/write a path nothing is mounted onto, and camoufox-js would decide
# the browser binary isn't installed and re-download ~1.3GB fetched at
# build time. `usermod -d /root node` keeps every existing path valid.
#
# Why chmod 755 on /root but NOT a recursive chown of its contents: /root
# itself is created mode 700 (root-only) by the base image, so a non-root
# user can't even `cd` into it without opening the directory's own
# permissions. But recursively chowning everything under /root (the
# ~1.3GB pre-baked Camoufox binary tree, node_modules caches, etc.) on
# every single container start would be slow and pointless -- nothing
# under /root/.cache or /app needs to be WRITABLE by the new user, only
# readable, and world-readable (755, the default most files already have)
# already covers that. Only /root/.camofox/{profiles,downloads} -- the
# directories actually written to at runtime -- get an explicit mkdir -p
# + chown, which is cheap because they're small/empty on a fresh volume.
set -e

if [ -n "${CAMOFOX_UID:-}" ] && [ -n "${CAMOFOX_GID:-}" ]; then
  chmod 755 /root
  usermod -d /root node 2>/dev/null || true
  groupmod -o -g "${CAMOFOX_GID}" node
  usermod -o -u "${CAMOFOX_UID}" node
  mkdir -p /root/.camofox/profiles /root/.camofox/downloads
  chown -R "${CAMOFOX_UID}:${CAMOFOX_GID}" /root/.camofox
  # /root/.cache/camoufox (the pre-baked browser binary tree) is read-only
  # for a non-root user by default (root:root, 755) -- fine for reading the
  # binary itself, but camoufox-js lazily creates new subdirectories under
  # it at runtime (observed: ".cache/camoufox/addons/<name>" the first time
  # an extension like uBlock Origin is fetched) and that mkdir fails EACCES
  # without write access on the parent dir itself. chown just this one
  # directory (not -R -- the ~1.3GB binary tree under it doesn't need to
  # change owner, only be listable/executable by someone who can already
  # read world-readable files, which 755 already allows) so new subdirs can
  # be created without recursively re-owning the whole Camoufox install on
  # every container start.
  # /root/.cache itself (not just /root/.cache/camoufox) needs the same
  # treatment: Firefox/Camoufox lazily creates several OTHER sibling cache
  # dirs directly under /root/.cache at runtime too -- .cache/fontconfig
  # (font cache) and .cache/dconf (GSettings backend) both failed with
  # EACCES/"Permission denied" in testing, each logged as noisy warnings on
  # every launch attempt even though they don't by themselves explain a
  # launch timeout. chown just /root/.cache itself (still NOT recursive --
  # .cache/camoufox's binary tree underneath keeps its own ownership from
  # the chown above) so any NEW sibling dir Firefox decides to create next
  # also just works, instead of patching this file again for the next one.
  chown "${CAMOFOX_UID}:${CAMOFOX_GID}" /root/.cache /root/.cache/camoufox
  export HOME=/root
  exec setpriv --reuid "${CAMOFOX_UID}" --regid "${CAMOFOX_GID}" --init-groups "$@"
fi

exec "$@"
