ldc2 -O2 sync-subtree.d

jj config set --user aliases.sync-subtree '["util", "exec", "--", "'"$(realpath ./sync-subtree)"'"]'
