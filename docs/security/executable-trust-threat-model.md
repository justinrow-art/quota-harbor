# Executable Trust Threat Model

## Boundary

The monitor accepts only the nested Codex executable declared in the bundled
trust manifest. It validates every path component, the parent and child
Developer ID designated-requirement shape, OpenAI Team and identifiers, nested
code, architecture, fixed arguments, and the minimum environment allowlist.
It does not search `PATH`, use another application, or fall back to a browser or
private endpoint.

## Path replacement risk

The installed ChatGPT app may be owned by the signed-in macOS user. Apple's
public `Process`/`posix_spawn` path API does not expose an execute-by-open-file-
descriptor operation. Consequently, a same-user attacker that can replace the
installed child retains a narrow race between the final userspace check and the
kernel's executable-path lookup.

The implementation narrows and detects this risk by:

1. opening the child with `O_EXEC | O_NOFOLLOW`, then binding preflight to its
   device, inode, size, and change time;
2. comparing that identity before and after static Security validation;
3. requiring the transport to repeat the identity check immediately before
   `Process.run()`;
4. dynamically validating the spawned PID before the first RPC, and terminating
   it on any mismatch.

No claim should describe this as a race-free sandbox or a security audit. A
strictly race-free design would require a different approved boundary, such as
a root-owned non-writable installation, a separately verified private snapshot,
or privileged execution mediation. Those approaches change the installation or
execution model and are outside the approved local-product scope.
