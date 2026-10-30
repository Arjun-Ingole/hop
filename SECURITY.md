# Security

hop runs as administrator and changes disks and startup entries, so please take care with anything
that could let someone else's code run, or damage a PC.

**To report a problem,** use "Report a vulnerability" on the repository's Security tab, which keeps it
private. Please don't open a public issue. Include how to reproduce it and what it could lead to.

Things worth reporting include downloading from anywhere but a project's official server, accepting
a file that fails its checksum, and deleting or changing a partition hop didn't make or wasn't asked
to remove.

## What hop does and doesn't check

- Downloads use HTTPS from each project's own server, and are checked against the SHA256 checksum the
  project publishes. **elementary OS publishes no checksum**, so that download relies on HTTPS alone.
- ISO files you pick yourself aren't verified. Only use ones you trust.
- `hop.exe` isn't code-signed yet, which is why Windows SmartScreen warns about it. Each release
  publishes a SHA256 checksum, and the build runs in public on GitHub Actions.
