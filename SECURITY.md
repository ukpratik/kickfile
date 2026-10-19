# Security policy

kickFile moves people's files, so security reports are taken seriously.

## Reporting a vulnerability

Please **don't open a public issue**. Use GitHub's private reporting: **Security › Report a vulnerability** on <https://github.com/ukpratik/kickfile>. Include the version, the platforms involved and steps to reproduce. You'll get a reply within 7 days, and a fix or a plan within 30 days for confirmed issues. Credit is given in the release notes unless you'd rather not.

## Supported versions

Only the latest release gets security fixes.

## Scope

In scope: anything that lets someone on the same network read, change or inject files, impersonate a trusted device, bypass the accept prompt, write outside the save folder, or crash or hang a device remotely. The design and its known limits are in [docs/PROTOCOL.md](docs/PROTOCOL.md#security-properties-and-non-goals).

Out of scope: attacks that need the unlocked device itself, a user who trusts a device without checking the 6-digit code, and denial of service by flooding the local network.
