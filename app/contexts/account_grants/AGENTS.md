Read the following guidelines before working in this directory:

@../../../docs/guidelines/event-sourcing.md

A destroyed account keeps its grant in the stream until the next deploy's `events:reconcile` records the removal. That is accepted: the account can't sign in, and its flag went with its row. Reconcile also records any flag written outside the operations as `already_held` with no grantor; [#539](https://github.com/espaliahq/espalia/issues/539) part 2 adds a lint rule against such writes.

The aggregate also loads role and link events (`AccountRoleSet`, `AccountRoleRemoved`, `AccountLinkedToPerson`, `AccountUnlinkedFromPerson`), which a later release writes. They live in `TenantAccountGrants` only: the repository links grant events back into the old stream, never these, because a release before them can't load them.
