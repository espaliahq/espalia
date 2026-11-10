# Security Policy

## Reporting a vulnerability

Email **security@espalia.app**. Do not open a public issue for anything you
believe is a security problem — an issue is visible to everyone before a fix
exists.

Include what you found, where (a URL path, a file, a commit), and how to
reproduce it. You'll get an acknowledgement within a few days, and we'll keep
you informed until the report is resolved. We're happy to credit you in the fix
unless you'd rather stay anonymous.

## Supported versions

Espalia is pre-1.0 and has no tagged releases yet: fixes land on `main` only.
If you deploy it, track `main` and keep your instance current.

## Known limitations

- **Google sign-in takes its callback URL from the request.** Today only
  Google's list of registered redirect URIs stops a forged one, so register
  only `APP_HOST` on the OAuth client, never a tenant's custom domain. Details
  and the planned fix:
  [integrations.md → Known limitation: the callback URL comes from the request](docs/architecture/integrations.md#known-limitation-the-callback-url-comes-from-the-request).

## Scope

The application in this repository, its MCP server and OAuth flows, and the
default deployment configuration. Vulnerabilities in third-party dependencies
are best reported upstream; tell us too if Espalia's usage makes one
exploitable.
