# jj-sync-subtree

This tool allows you to sync a subtree of remote `git`/`jj` repository into a `jj` repository.

```
Usage:
  sync-subtree <repository> <subtree>
  sync-subtree <repository> <subtree> --branch <name>
  sync-subtree <repository> <subtree> --commit <hash>
```

The initial sync is basically equivalent to doing a `git clone` at the given `<subtree>` path, but without producing a `.git` directory.

Later syncs will create a new revision titled `Sync '<subtree>' from commit 1ab23cd4` with a revision stacked on top titled `Apply local patches to '<subtree>`. The sync revision contains the whole remote commit, as it exists on the remote, while the patch revision contains all local patches since the last sync.

# Installation

Compile the tool:

```
ldc2 -O2 sync-subtree.d
```

To make the command available as `jj sync-subtree`, run:

```
jj config set --user aliases.sync-subtree '["util", "exec", "--", "'"$(realpath ./sync-subtree)"'"]'
```
