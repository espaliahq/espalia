Read the following guidelines before working in this directory:

@../../../docs/guidelines/event-sourcing.md

The stream is the only place that holds retention and scheduled forgetting. Every command removes the retention keys from `tenants.org_graph_config`, because the previous release writes them back while a deploy is in flight, and its predeploy would record them over the stream if it were deployed again. Never deploy a release older than that one, which read the JSON alone: see [org-graph-forgetting.md](../../../docs/runbooks/org-graph-forgetting.md).
