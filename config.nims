# Required compiler flags for observy.
# Consumers of this library must also compile with --mm:orc --threads:on.
switch("mm", "orc")
switch("threads", "on")
