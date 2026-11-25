Read the following guidelines before working in this directory:

@../../../docs/guidelines/event-sourcing.md

The stream is the only place anything reads retention and scheduled forgetting from. Every command still writes them to `tenants.org_graph_config` too, because the previous release reads that JSON and records what it holds before each of its own commands: a JSON that fell behind the stream would be written back over it. [#539](https://github.com/espaliahq/espalia/issues/539) Track C's c2b stops writing the JSON and removes the keys, once this release serves everywhere.
