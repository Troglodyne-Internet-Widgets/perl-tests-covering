# NAME

Perl::Tests::Covering - Which tests run the file you just changed, from coverage kept on disk.

# VERSION

version 0.002

# SYNOPSIS

```perl
use Perl::Tests::Covering;

my $covering = Perl::Tests::Covering->new( root => '/src/My-Dist' );

# The tests that load a file.
my @tests = $covering->tests_covering('lib/My/Dist.pm');

# The tests that ran the lines a change touches.
my @chosen = $covering->tests_covering_diff( scalar `git diff --cached` );

# The tests that ran a sub, and the files a test loaded.
my @callers = $covering->tests_covering_sub( 'lib/My/Dist.pm', 'frobnicate' );
my @files   = $covering->files_covered_by('t/frobnicate.t');
```

# DESCRIPTION

You change one module, and you want to run the tests that exercise it and not
the rest.  This module tells you which tests those are.

It runs each test of a distribution once under [Devel::Cover](https://metacpan.org/pod/Devel%3A%3ACover), and records
every file of the distribution that the test loaded.  A later question about a
file is answered from that record.  A test is run again only when the record
for it is stale: when the test is new, or when the test or any file it loaded
changed since the record was made.

It also records which lines of each file each test ran.  So it can answer at
a finer grain: which tests ran a given sub, and which tests ran the lines that
a diff changes.

The answer is meant for a git pre-commit hook.  Hand it the files or the diff
of a changeset, and run what comes back.  [tests-covering](https://metacpan.org/pod/tests-covering) is the command
line for it, and has the hooks:

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

A record holds the git blob id of each file the test loaded, which is the
SHA-1 that git gives the content.  The record is stale when any of those ids
changed, or when any of those files is gone.  A test that loads a new module
can only do so because a file it already loaded changed, so the new module
needs no id of its own.

The exception is code that finds modules at run time without naming them, for
example [Module::Pluggable](https://metacpan.org/pod/Module%3A%3APluggable).  A new plugin of that kind does not make a record
stale.  Neither does a change to the environment, such as `AUTHOR_TESTING`,
that changes what a test runs.  ["THE MAP"](#the-map) is how a distribution says which
tests a new plugin reaches.

## A FILE THAT CHANGED OR IS GONE

["tests\_covering"](#tests_covering) reports a test that covers the file now, and also a test
that covered it before its records were brought up to date.  So a module that
you deleted is still reported as covered by the tests that used it, which are
the tests that the deletion breaks.

## CHOOSING TESTS FOR A CHANGE

["tests\_covering\_diff"](#tests_covering_diff) chooses tests by the lines a diff changes.  The
numbers in a diff are the lines of each file before the change.  So it reads
the records as they are and runs nothing, and a record only helps when it was
made of the file as the diff's `index` line names it.  Bring the records up
to date after each commit, with ["refresh"](#refresh), and the next diff finds them.
[tests-covering](https://metacpan.org/pod/tests-covering) has a post-commit hook that does that.

A test is chosen when any of these is true:

- it has no record, or it is in the diff;
- a file it loaded changed since its record, and the diff does not say how;
- the diff deletes or moves a file it loaded, or changes the file without a
hunk, such as its mode;
- its record of a file in the diff is of another version than the diff's old
side, or the diff has no `index` line to say which;
- it ran a line that the diff changes, or code the diff adds goes in among lines
it ran.

The last rule needs to know where each statement is, and PPI says that.  A
changed line counts as run when the test ran the statement that holds it, so
a change to the second line of a statement over three lines counts.  So does a
change to the brace that closes a block the test ran.  Code added inside a sub
counts as run by the tests that ran that sub.  Blank lines, comments and POD
count for nothing, in the old version as the record has it, and in the new one
when the file in the work tree is what the diff made it.  A string or a
heredoc body that looks like a comment is still code.

Some code runs whenever the file is loaded, and Devel::Cover does not count it
in a module: the code at the top of the file, and a `package` line.  A change
there, or code added between two subs, chooses every test that loads the file.
So does adding a whole sub, since a new `import`, `DESTROY` or method can
change what code that never called it does.

Choosing by line trusts that each changed file still compiles.  A syntax error
in a sub that no test runs chooses no tests, and still breaks every test that
loads the file.  [tests-covering](https://metacpan.org/pod/tests-covering) says how to have the hook check that too.

## THE MAP

Some files reach a test without the test loading them.  A template that a
test renders is one: the test reads it, and Perl does not record a read.
Watching which files a test opens does not help either, as a template engine
with a cache of compiled templates can read only its cache.  A script that a
test runs under another perl is a second kind, since that perl cannot load
[Perl::Tests::Covering::Recorder](https://metacpan.org/pod/Perl%3A%3ATests%3A%3ACovering%3A%3ARecorder).  Only the distribution knows which tests
reach such files, and the map is how it says so.

The map is a code reference.  It is called once for each path in the question
that is not a test and that no record names as loaded:

```perl
use Perl::Tests::Covering qw{NO_TESTS};

sub {
    my ( $path, $change ) = @_;
    return 't/templates.t'  if $path =~ m{\Atemplates/};
    return 'lib/Plugins.pm' if $path =~ m{\Alib/Plugin/.+[.]pm\z};
    return NO_TESTS         if $path =~ m{\Adocs/};
    return;
}
```

`$path` is relative to the root.  `$change` is the change to it from a diff,
as below, or undef when the question is ["tests\_covering"](#tests_covering).  The map runs with
the root as the working directory, and with the library directories at the
front of `@INC`, so it can ask the distribution's own modules.  When it dies,
the question dies.

It returns paths relative to the root:

- a test, which is chosen;
- any other file, which stands in for `$path`: each test that loaded that file
is chosen, whatever lines the change touched;
- `NO_TESTS`, which says that `$path` reaches no test;
- nothing, which leaves `$path` unexplained.

`NO_TESTS` is exported on request, and is the empty string, so a map can
return `q{}` instead.

A path counts as explained when the map chooses a test for it, or says
`NO_TESTS`.  A stand-in that no test loads chooses nothing, so it leaves the
path unexplained.  That happens when the stand-in is new, for example a
plugin that comes in the same diff as its template.  A path that is neither a
test nor a file under the root is dropped with a warning, so a mistake in the
map leaves the path unexplained, and does not explain it away.

A path that is unexplained chooses no test, unless the `unexplained` option
is `all`, which chooses every test.

A Perl file that a diff adds is asked about too, since code that finds modules
at run time, such as [Module::Pluggable](https://metacpan.org/pod/Module%3A%3APluggable), loads it with nothing in the diff
using it.  When the map says nothing about it, it counts as explained: the
files that use it are usually in the diff, and a distribution without plugins
does not run every test each time it adds a module.

The map answers when the question is asked, so it adds nothing to the cache,
and a change to it makes no record stale.

The change is a hash:

- `old`, `new`

    The path before and after, relative to the root.  Undef for a file the diff
    adds or deletes, and for a path outside the root.

- `old_blob`, `new_blob`

    The git blob ids from the `index` line, which may be abbreviated, or undef.

- `hunks`

    How many hunks the diff has for the file.

- `blocks`

    Each run of removed and added lines, as a hash: `at`, the old line the run
    starts at, or that the added lines go in before when nothing is removed;
    `deleted`, the old line numbers removed, and `deleted_text`, their text;
    `added`, the new line numbers added, and `added_text`, their text.  The text
    has no line end.

## THE CACHE ON DISK

The records of a distribution are one file of gzipped JSON, in
`$XDG_CACHE_HOME/perl-tests-covering`, or `~/.cache/perl-tests-covering` when
`XDG_CACHE_HOME` is not set.  The file name is the SHA-1 of the root.  The
root is also in the gzip header, so that the cache of a root which is gone can
be removed without reading the whole file.  That removal happens each time a
cache is written.

Beside the records, the cache keeps the layout of each version of a file that
a record names, keyed by blob id: the lines that Devel::Cover counts a
statement on, where PPI finds each statement, and which lines are blank,
comments or POD.

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
code is all at the top of the file, and the recorder does.

A test with `-T` or `-t` on its `#!` line runs with that switch, as
`prove` runs it.  Perl ignores `PERL5LIB` and `PERL5OPT` under taint, so
for such a test they also go on the command line, as `-I` and `-M`
switches.

Standard input, output and error go to the null device.  A test that fails
still has its coverage recorded, because the question is what it ran, not
whether it passed.

Each run writes to a temporary coverage database of its own, and the database
is deleted after it is read.  Nothing is written to `cover_db`.  The lines a
test ran are only kept for a file whose content, when the run is read, is what
Devel::Cover counted.  A file that changed while the test ran has no lines in
the record, and a question about its lines chooses the test.

## COMPARED WITH Devel::CoverX::Covered

[Devel::CoverX::Covered](https://metacpan.org/pod/Devel::CoverX::Covered) answers the same question from a `cover_db` that you
make yourself: you run the whole suite under Devel::Cover, then run `covered
runs` before `cover` merges the runs away.  This comparison is of its release
0.016, run on the same small distribution as this module.

It does more in two ways.  It reports how often each sub ran, with `covered
subs`.  And it reads a `cover_db` from any run of the suite, such as one in CI,
and editors reach it through [Devel::PerlySense](https://metacpan.org/pod/Devel::PerlySense) and vim-covered.  This
module runs the tests itself.

This module does more in five ways.

- It keeps its answers current.  Devel::CoverX::Covered has no idea of a stale
record.  After a test changes, it gives the old answer until the whole suite
runs again under Devel::Cover, and a deleted test stays in its answers, as its
own documentation says.  This module runs again only the tests whose files
changed.
- It reports the test.  Devel::CoverX::Covered takes each perl process as a test,
by its `$0`.  So when a test runs `bin/foo` in a child perl, it reports
`bin/foo` as the test that covers the modules `bin/foo` uses, and does not
report the test.
- It counts every file a test loads.  Devel::CoverX::Covered counts a file only
when a named sub in it ran.  So it reports no test for a module that a test
loads and never calls, for a module that is all code at the top of the file,
for a script without subs, or for the test itself.
- It chooses by the lines of a diff.  Devel::CoverX::Covered chooses by file or
by sub, and lists choosing by line as not done.
- It can be told about files that no test loads, such as templates, through
["THE MAP"](#the-map), and it can run every test for a change that nothing explains.
Devel::CoverX::Covered knows only the files Devel::Cover measured, and chooses
no test for any other.

Both answer the question turned around, which files a test covers, and both
choose by sub.  Devel::CoverX::Covered needs `Moose`, `DBD::SQLite`,
`DBIx::Simple`, `SQL::Abstract`, `Path::Class` and `File::chdir`.

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

- `map`

    What says which tests reach a file that no test loads: a code reference, or
    the name of a Perl file that returns one.  ["THE MAP"](#the-map) says what it is called
    with and what it returns.  The default is `.tests-covering-map.pl` in the
    root, when there is one.  Pass `undef` for no map.  It dies when the file
    does not compile or does not return a code reference.

- `unexplained`

    What to do about a file in the question that neither a record nor the map
    explains: `none`, the default, chooses no test for it, and `all` chooses
    every test.

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
line.  A file outside the root adds nothing.  A file that no test loads adds
what the map and `unexplained` say, as ["THE MAP"](#the-map) describes.

It calls ["refresh"](#refresh) first, so it can take as long as the stale tests take to
run.  A test is reported when its record from before the refresh, or its record
from after it, says it covers one of the files.  See
["A FILE THAT CHANGED OR IS GONE"](#a-file-that-changed-or-is-gone).

## tests\_covering\_diff

```perl
my @tests = $covering->tests_covering_diff($diff);
```

The tests that a change could break, relative to the root, sorted.  `$diff`
is the text of a unified diff from git, such as `git diff --cached`.  Its
paths are relative to the current directory, which for git is the top of the
work tree.

It does not run anything first.  The line numbers of a diff describe the files
before the change, so the answer has to come from records made of those files.
See ["CHOOSING TESTS FOR A CHANGE"](#choosing-tests-for-a-change), which also says when it runs a test that
the change may not reach.

## tests\_covering\_sub

```perl
my @tests = $covering->tests_covering_sub( $file, $name );
```

The tests that ran any statement of the sub `$name` in `$file`, relative to
the root, sorted.  `$name` matches with or without its package.  It calls
["refresh"](#refresh) first, and dies when `$file` has no such sub.

A test whose record has no lines for `$file` is reported when it loaded the
file at all, as ["tests\_covering"](#tests_covering) would.

## files\_covered\_by

```perl
my @files = $covering->files_covered_by($test);
```

The files that `$test` loaded, relative to the root, sorted: the reverse of
["tests\_covering"](#tests_covering).  It calls ["refresh"](#refresh) first.  A test that is not a test of
the distribution covers nothing.

# SEE ALSO

Please see those modules/websites for more information related to this module.

- [tests-covering](https://metacpan.org/pod/tests-covering)
- [Devel::Cover](https://metacpan.org/pod/Devel%3A%3ACover)
- [Perl::Critic::Policy::ProhibitUnusedDefinitions](https://metacpan.org/pod/Perl%3A%3ACritic%3A%3APolicy%3A%3AProhibitUnusedDefinitions)

# BUGS

Please report any bugs or feature requests on the bugtracker website
[https://github.com/Troglodyne-Internet-Widgets/perl-tests-covering/issues](https://github.com/Troglodyne-Internet-Widgets/perl-tests-covering/issues)

When submitting a bug or request, please include a test-file or a
patch to an existing test-file that illustrates the bug or desired
feature.

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
