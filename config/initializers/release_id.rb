# frozen_string_literal: true

# Identifier for the running build of the application code.
#
# Mixed into the explorer's conditional-GET keys (see
# {Frameworks::ExplorerMatrix#explorer_matrix_etag}) so a deploy that changes
# markup can never be answered with a 304 built from the previous release's
# HTML — the data an ETag is derived from is unchanged by a code change, so
# without this the browser would keep rendering the old grid.
#
# Prefers the platform's commit SHA (Render injects RENDER_GIT_COMMIT), which
# is stable across workers and restarts of the same release. The fallback is a
# per-process token: correct, but distinct per worker, so a cross-worker
# request pays a full render instead of a 304 — a missed cache hit, never a
# stale one.
Rails.application.config.x.release_id =
  ENV["RENDER_GIT_COMMIT"].presence ||
  ENV["GIT_COMMIT"].presence ||
  SecureRandom.hex(8)
