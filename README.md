# NAME

Perl::Tests::Covering - Which tests run the file you just changed, from coverage kept on disk.

# VERSION

version 0.001

# SYNOPSIS

```perl
use Perl::Tests::Covering;

my $covering = Perl::Tests::Covering->new( root => '/src/My-Dist' );
my @tests    = $covering->tests_covering('lib/My/Dist.pm');
```

# DESCRIPTION

You change one module, and you want to run the tests that exercise it and not
the rest.  This module tells you which tests those are.

It runs each test of a distribution once under [Devel::Cover](https://metacpan.org/pod/Devel%3A%3ACover), and records
every file of the distribution that the test loaded.  A later question about a
file is answered from that record.  A test is run again only when the record
for it is stale: when the test is new, or when the test or any file it loaded
changed since the record was made.

The answer is meant for a git pre-commit hook.  Hand it the files of a
changeset, and run what comes back.  [tests-covering](https://metacpan.org/pod/tests-covering) is the command line for
it, and has the hook:

```
tests-covering lib/My/Dist.pm | xargs --no-run-if-empty prove -l
```

## WHAT COUNTS AS COVERING

A test covers a file when the file was loaded during a run of the test.  That
includes the test itself, helpers under `t/lib`, and scripts in `bin/` that
the test runs in a child perl.  A module the test loads but never calls still
counts.  A syntax error in it fails the test all the same.

Only perl code is tracked.  A test that reads a template, a fixture or a
configuration file is not reported as covering that file.

## WHEN A RECORD GOES STALE

A record holds the SHA-1 digest of each file the test loaded.  The record is
stale when any of those digests changed, or when any of those files is gone.
A test that loads a new module can only do so because a file it already
loaded changed, so the new module needs no digest of its own.

The exception is code that finds modules at run time without naming them, for
example [Module::Pluggable](https://metacpan.org/pod/Module%3A%3APluggable).  A new plugin of that kind does not make a record
stale.  Neither does a change to the environment, such as `AUTHOR_TESTING`,
that changes what a test runs.

## A FILE THAT CHANGED OR IS GONE

["tests\_covering"](#tests_covering) reports a test that covers the file now, and also a test
that covered it before its records were brought up to date.  So a module that
you deleted is still reported as covered by the tests that used it, which are
the tests that the deletion breaks.

## THE CACHE ON DISK

The records of a distribution are one file of gzipped JSON, in
`$XDG_CACHE_HOME/perl-tests-covering`, or `~/.cache/perl-tests-covering` when
`XDG_CACHE_HOME` is not set.  The file name is the SHA-1 of the root.  The
root is also in the gzip header, so that the cache of a root which is gone can
be removed without reading the whole file.  That removal happens each time a
cache is written.

The cache also records the stamp of this module's file, the version of perl,
and the configured test and library directories.  If any of them changes, all
of the records are stale.

A cache that cannot be read is treated as empty.  A cache that cannot be
written costs the next run the coverage runs again, and nothing else.

## RUNNING THE TESTS

Each stale test runs under `perl -MDevel::Cover` with the root as its working
directory, with `HARNESS_ACTIVE` set, and with the library directories added
to `PERL5LIB`.  `Devel::Cover` goes in `PERL5OPT`, so a perl that the test
starts is covered too.

[Perl::Tests::Covering::Recorder](https://metacpan.org/pod/Perl%3A%3ATests%3A%3ACovering%3A%3ARecorder) goes in `PERL5OPT` as well, and writes
down `%INC` as each perl exits.  Devel::Cover does not record a module whose
code is all at the top of the file, and the recorder does.  Standard input, output and error go to the null
device.  A test that fails still has its coverage recorded, because the
question is what it ran, not whether it passed.

Each run writes to a temporary coverage database of its own, and the database
is deleted after it is read.  Nothing is written to `cover_db`.

# CONSTRUCTOR

## new

```perl
my $covering = Perl::Tests::Covering->new(%options);
```

Every option is optional.

- `root`

    The root of the distribution.  The default is the nearest directory, from the
    current directory upwards, that holds a `dist.ini`, `Makefile.PL`,
    `Build.PL`, `cpanfile`, `META.json` or `.git`.  It dies when there is none.

- `tests`

    The directories, relative to the root, that hold the tests.  Every `.t` file
    under them is a test.  The default is `['t']`.

- `lib`

    The directories, relative to the root, that go in `PERL5LIB` for each run.
    The default is `['lib']`, like `prove -l`.

- `jobs`

    How many tests run at once.  The default is 1.

- `cache_dir`

    Where the cache is kept.  The default is described in ["THE CACHE ON DISK"](#the-cache-on-disk).

# METHODS

## root

The absolute path of the root, with symbolic links resolved.

## tests

Every test of the distribution, relative to the root, sorted.

## refresh

```perl
my @ran = $covering->refresh();
```

Brings the records up to date: runs each test that is stale under coverage,
drops the record of each test that is gone, and writes the cache when anything
changed.  Returns the tests it ran, relative to the root.

["tests\_covering"](#tests_covering) calls this for you.

## tests\_covering

```perl
my @tests = $covering->tests_covering(@files);
```

The tests that cover any of `@files`, relative to the root, sorted.  A file
that is relative is relative to the current directory, as it is on a command
line.  A file outside the root, or covered by no test, adds nothing.

It calls ["refresh"](#refresh) first, so it can take as long as the stale tests take to
run.  A test is reported when its record from before the refresh, or its record
from after it, says it covers one of the files.  See
["A FILE THAT CHANGED OR IS GONE"](#a-file-that-changed-or-is-gone).

# SEE ALSO

Please see those modules/websites for more information related to this module.

- [tests-covering](https://metacpan.org/pod/tests-covering)
- [Devel::Cover](https://metacpan.org/pod/Devel%3A%3ACover)
- [Perl::Critic::Policy::ProhibitUnusedDefinitions](https://metacpan.org/pod/Perl%3A%3ACritic%3A%3APolicy%3A%3AProhibitUnusedDefinitions)

# AUTHORS

Current Maintainers:

- George S. Baugh <george@troglodyne.net>

# COPYRIGHT AND LICENSE

Copyright (c) 2026 Troglodyne LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
