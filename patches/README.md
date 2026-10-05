# patches

One folder per patch, in application order:

    patches/<NNNN-slug>/
        <NNNN-slug>.patch     the patch, as applied to the tree
        RESULT.md             what we found when we tested it

`build.sh` applies `patches/[0-9]*/*.patch` in filename order, so the number is the
application order. The leading digit in the folder name is also what keeps the series
folder below out of the build — it holds an upstream series, not patches of ours:

    asus-zenbook-a16-a14-ec-v3/    the ASUS EC series as posted upstream, with our
                                   comparison against it, the evidence from testing
                                   it, and the test scripts

Nothing here is a scratch name from a DTB workflow; every file is an ordinary source
patch against the tree. §4 of `../BRINGUP/port-2026-10-03/readme.md` says why that is
worth stating.

Hashes for everything applied live in `../BRINGUP/port-2026-10-03/MANIFEST.sha256`,
which verifies from the port directory:

    cd ../BRINGUP/port-2026-10-03
    sha256sum -c --ignore-missing MANIFEST.sha256

The old-numbered copies of the same patches are still in `../BRINGUP/patches/`; they
predate the renumbering, are not applied by anything, and are referenced by
`../docs/display-*.md`.
