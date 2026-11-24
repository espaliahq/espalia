Read the following guidelines before working in this directory:

@../../../docs/guidelines/event-sourcing.md

While the release before this stream may still serve, it writes retention and scheduled forgetting to `tenants.org_graph_config` only. So every command first records what that JSON holds, and both places must say yes before anyone is forgotten. [#539](https://github.com/espaliahq/espalia/issues/539) Track C's c2 drops the JSON keys.
