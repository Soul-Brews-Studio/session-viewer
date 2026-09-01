# Security and privacy

The local app reads paths selected by the operator and writes only its local
rebuildable cache. Do not commit `.data/`, JSONL transcripts, credentials,
private hostnames, or generated build products containing corpus data.

The public Worker contains synthetic fixtures only and has no persistence or
private-data bindings. Please report vulnerabilities privately to maintainers.
