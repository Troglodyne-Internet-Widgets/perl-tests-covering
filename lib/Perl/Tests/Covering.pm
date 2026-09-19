package Perl::Tests::Covering;

# ABSTRACT: Which tests run the file you just changed, from coverage kept on disk.

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

use Readonly;

use Carp                   ();
use Config                 ();
use Cwd                    ();
use Cpanel::JSON::XS       ();
use Devel::Cover::DB       ();
use Digest::SHA            ();
use File::Find             ();
use File::Path             ();
use File::Slurper          ();
use File::Slurper::Temp    ();
use File::Spec             ();
use File::Temp             ();
use IO::Compress::Gzip     ();
use IO::Uncompress::Gunzip ();
use POSIX                  ();

=head1 SYNOPSIS

    use Perl::Tests::Covering;

    my $covering = Perl::Tests::Covering->new( root => '/src/My-Dist' );
    my @tests    = $covering->tests_covering('lib/My/Dist.pm');

=head1 DESCRIPTION

You change one module, and you want to run the tests that exercise it and not
the rest.  This module tells you which tests those are.

It runs each test of a distribution once under L<Devel::Cover>, and records
every file of the distribution that the test loaded.  A later question about a
file is answered from that record.  A test is run again only when the record
for it is stale: when the test is new, or when the test or any file it loaded
changed since the record was made.

The answer is meant for a git pre-commit hook.  Hand it the files of a
changeset, and run what comes back.  L<tests-covering> is the command line for
it, and has the hook:

    tests-covering lib/My/Dist.pm | xargs --no-run-if-empty prove -l

=head2 WHAT COUNTS AS COVERING

A test covers a file when the file was loaded during a run of the test.  That
includes the test itself, helpers under F<t/lib>, and scripts in F<bin/> that
the test runs in a child perl.  A module the test loads but never calls still
counts.  A syntax error in it fails the test all the same.

Only perl code is tracked.  A test that reads a template, a fixture or a
configuration file is not reported as covering that file.

=head2 WHEN A RECORD GOES STALE

A record holds the SHA-1 digest of each file the test loaded.  The record is
stale when any of those digests changed, or when any of those files is gone.
A test that loads a new module can only do so because a file it already
loaded changed, so the new module needs no digest of its own.

The exception is code that finds modules at run time without naming them, for
example L<Module::Pluggable>.  A new plugin of that kind does not make a record
stale.  Neither does a change to the environment, such as C<AUTHOR_TESTING>,
that changes what a test runs.

=head2 A FILE THAT CHANGED OR IS GONE

L</tests_covering> reports a test that covers the file now, and also a test
that covered it before its records were brought up to date.  So a module that
you deleted is still reported as covered by the tests that used it, which are
the tests that the deletion breaks.

=head2 THE CACHE ON DISK

The records of a distribution are one file of gzipped JSON, in
F<$XDG_CACHE_HOME/perl-tests-covering>, or F<~/.cache/perl-tests-covering> when
C<XDG_CACHE_HOME> is not set.  The file name is the SHA-1 of the root.  The
root is also in the gzip header, so that the cache of a root which is gone can
be removed without reading the whole file.  That removal happens each time a
cache is written.

The cache also records the stamp of this module's file, the version of perl,
and the configured test and library directories.  If any of them changes, all
of the records are stale.

A cache that cannot be read is treated as empty.  A cache that cannot be
written costs the next run the coverage runs again, and nothing else.

=head2 RUNNING THE TESTS

Each stale test runs under C<perl -MDevel::Cover> with the root as its working
directory, with C<HARNESS_ACTIVE> set, and with the library directories added
to C<PERL5LIB>.  C<Devel::Cover> goes in C<PERL5OPT>, so a perl that the test
starts is covered too.

L<Perl::Tests::Covering::Recorder> goes in C<PERL5OPT> as well, and writes
down C<%INC> as each perl exits.  Devel::Cover does not record a module whose
code is all at the top of the file, and the recorder does.  Standard input, output and error go to the null
device.  A test that fails still has its coverage recorded, because the
question is what it ran, not whether it passed.

Each run writes to a temporary coverage database of its own, and the database
is deleted after it is read.  Nothing is written to F<cover_db>.

=cut

# Change it when what the cache holds changes shape.
Readonly::Scalar my $CACHE_FORMAT => 1;

Readonly::Scalar my $CACHE_NAME => 'perl-tests-covering';

# What this module names the files in its cache directory.
Readonly::Scalar my $CACHE_FILE_RX => qr/\A[0-9a-f]{40}[.]json[.]gz\z/;

# The files that say a directory is the root of a distribution.
Readonly::Array my @DIST_MARKERS => qw{dist.ini Makefile.PL Build.PL cpanfile META.json .git};

# What exec returns with in a child that could not become the test.
Readonly::Scalar my $EXEC_FAILED => 127;

# The directory this module was loaded from, so that a run can load the
# recorder from the same place.  Taken now, because __FILE__ may be relative to
# the directory we started in.
Readonly::Scalar my $OWN_LIB => File::Spec->rel2abs(__FILE__) =~ s{[/\\]Perl[/\\]Tests[/\\]Covering[.]pm\z}{}r;

=head1 CONSTRUCTOR

=head2 new

    my $covering = Perl::Tests::Covering->new(%options);

Every option is optional.

=over 4

=item C<root>

The root of the distribution.  The default is the nearest directory, from the
current directory upwards, that holds a F<dist.ini>, F<Makefile.PL>,
F<Build.PL>, F<cpanfile>, F<META.json> or F<.git>.  It dies when there is none.

=item C<tests>

The directories, relative to the root, that hold the tests.  Every F<.t> file
under them is a test.  The default is C<['t']>.

=item C<lib>

The directories, relative to the root, that go in C<PERL5LIB> for each run.
The default is C<['lib']>, like C<prove -l>.

=item C<jobs>

How many tests run at once.  The default is 1.

=item C<cache_dir>

Where the cache is kept.  The default is described in L</THE CACHE ON DISK>.

=back

=cut

sub new {
    my ( $class, %opts ) = @_;

    my %known   = map  { $_ => 1 } qw{root tests lib jobs cache_dir};
    my @unknown = grep { !$known{$_} } sort keys %opts;
    Carp::croak("Unknown option(s) to $class->new: @unknown") if @unknown;

    my $root = defined $opts{root} ? Cwd::abs_path( $opts{root} ) : _find_root( Cwd::getcwd() );
    Carp::croak( 'No root: ' . ( $opts{root} // 'no distribution above ' . Cwd::getcwd() ) ) if !defined $root || !-d $root;

    foreach my $list (qw{tests lib}) {
        Carp::croak("$list must be a list of directories, not '$opts{$list}'") if defined $opts{$list} && ref $opts{$list} ne 'ARRAY';
    }

    my $jobs = $opts{jobs} // 1;
    Carp::croak("jobs must be a whole number of 1 or more, not '$jobs'") if $jobs !~ m/\A[1-9][0-9]*\z/;

    return bless {
        root      => $root,
        tests     => [ @{ $opts{tests} // ['t'] } ],
        lib       => [ @{ $opts{lib}   // ['lib'] } ],
        jobs      => $jobs,
        cache_dir => $opts{cache_dir} // _default_cache_dir(),
        digest    => {},
    }, $class;
}

=head1 METHODS

=head2 root

The absolute path of the root, with symbolic links resolved.

=cut

sub root { return $_[0]{root} }

=head2 tests

Every test of the distribution, relative to the root, sorted.

=cut

sub tests {
    my ($self) = @_;

    my @tests;
    foreach my $dir ( grep { -d } map { File::Spec->catdir( $self->{root}, $_ ) } @{ $self->{tests} } ) {
        File::Find::find( { no_chdir => 1, wanted => sub { push @tests, $File::Find::name if m/[.]t\z/ && -e && !-d } }, $dir );
    }
    return sort map { File::Spec->abs2rel( $_, $self->{root} ) } @tests;
}

=head2 refresh

    my @ran = $covering->refresh();

Brings the records up to date: runs each test that is stale under coverage,
drops the record of each test that is gone, and writes the cache when anything
changed.  Returns the tests it ran, relative to the root.

L</tests_covering> calls this for you.

=cut

sub refresh {
    my ($self) = @_;

    # A file edited between two refreshes has a new digest.
    $self->{digest} = {};

    my $before = $self->_read_cache();
    my ( %after, @stale );
    foreach my $test ( $self->tests() ) {
        if ( $self->_is_fresh( $before->{$test} ) ) {
            $after{$test} = $before->{$test};
            next;
        }
        push @stale, $test;
    }

    my $ran = $self->_run_tests(@stale);
    @after{ keys %$ran } = values %$ran;

    my $changed = @stale || grep { !$after{$_} } keys %$before;
    $self->_write_cache( \%after ) if $changed;

    $self->{before} = $before;
    $self->{after}  = \%after;
    return @stale;
}

=head2 tests_covering

    my @tests = $covering->tests_covering(@files);

The tests that cover any of C<@files>, relative to the root, sorted.  A file
that is relative is relative to the current directory, as it is on a command
line.  A file outside the root, or covered by no test, adds nothing.

It calls L</refresh> first, so it can take as long as the stale tests take to
run.  A test is reported when its record from before the refresh, or its record
from after it, says it covers one of the files.  See
L</A FILE THAT CHANGED OR IS GONE>.

=cut

sub tests_covering {
    my ( $self, @files ) = @_;

    my @wanted = grep { defined } map { $self->_relative( $_, Cwd::getcwd() ) } @files;
    $self->refresh();

    my %covering;
    foreach my $records ( $self->{before}, $self->{after} ) {
        foreach my $test ( keys %$records ) {
            $covering{$test} = 1 if grep { exists $records->{$test}{loaded}{$_} } @wanted;
        }
    }

    # A test that is gone covers nothing it could be run for.
    return sort grep { $self->{after}{$_} } keys %covering;
}

# The nearest directory, from $dir upwards, that holds a distribution.
sub _find_root {
    my ($dir) = @_;

    my ( $volume, $directories ) = File::Spec->splitpath( $dir, 1 );
    my @dirs = File::Spec->splitdir($directories);
    while (@dirs) {
        my $candidate = File::Spec->catpath( $volume, File::Spec->catdir(@dirs), q{} );
        return Cwd::abs_path($candidate) if grep { -e File::Spec->catfile( $candidate, $_ ) } @DIST_MARKERS;
        pop @dirs;
    }
    return;
}

sub _default_cache_dir {
    my $base = $ENV{XDG_CACHE_HOME} || ( $ENV{HOME} && File::Spec->catdir( $ENV{HOME}, '.cache' ) ) or return;
    return File::Spec->catdir( $base, $CACHE_NAME );
}

# $file relative to the root, or undef when it is not under the root.  A
# relative $file is relative to $base.  Only the directory has to exist, so
# that a file which was deleted still has a name.
sub _relative {
    my ( $self, $file, $base ) = @_;

    my $abs = File::Spec->rel2abs( $file, $base );
    my ( $volume, $dirs, $name ) = File::Spec->splitpath($abs);
    my $dir = Cwd::abs_path( File::Spec->catpath( $volume, $dirs, q{} ) ) // return;

    my $rel = File::Spec->abs2rel( File::Spec->catfile( $dir, $name ), $self->{root} );
    return if File::Spec->file_name_is_absolute($rel) || ( File::Spec->splitdir($rel) )[0] eq File::Spec->updir();
    return $rel;
}

# The SHA-1 of a file relative to the root, or undef when it cannot be read.
# Kept for the length of one refresh.
sub _digest {
    my ( $self, $rel ) = @_;

    return $self->{digest}{$rel} if exists $self->{digest}{$rel};

    my $path = File::Spec->catfile( $self->{root}, $rel );
    my $sha  = -e $path && !-d _ && eval { Digest::SHA->new(1)->addfile( $path, 'b' )->hexdigest() };
    return $self->{digest}{$rel} = $sha || undef;
}

# Whether a record was made from every file it names as that file is now.
sub _is_fresh {
    my ( $self, $record ) = @_;

    return if ref $record ne 'HASH' || ref $record->{loaded} ne 'HASH' || !%{ $record->{loaded} };
    foreach my $file ( keys %{ $record->{loaded} } ) {
        my $now = $self->_digest($file) // return;
        return if $now ne $record->{loaded}{$file};
    }
    return 1;
}

# Runs each test under coverage, $self->{jobs} at a time, and returns a record
# for each, keyed by test.
sub _run_tests {
    my ( $self, @queue ) = @_;

    my ( %running, %records );
    while ( @queue || %running ) {
        while ( @queue && keys %running < $self->{jobs} ) {
            my $test = shift @queue;
            my $tmp  = File::Temp->newdir();
            $running{ $self->_spawn( $test, $tmp->dirname() ) } = [ $test, $tmp ];
        }

        my $pid = waitpid -1, 0;
        last if $pid < 0;

        # Some other child of whoever called us.
        my $job = delete $running{$pid} or next;
        $records{ $job->[0] } = $self->_record( $job->[0], $job->[1]->dirname() );
    }
    return \%records;
}

# Starts one test under coverage, silently, and returns its pid.  Devel::Cover
# writes to cover_db under $tmp, and the recorder to loaded.
sub _spawn {
    my ( $self, $test, $tmp ) = @_;

    my $loaded = File::Spec->catdir( $tmp, 'loaded' );
    mkdir $loaded or Carp::croak("Cannot make $loaded: $!");

    my $pid = fork // Carp::croak("Cannot fork to run $test: $!");
    return $pid if $pid;

    # From here on, this is the child, and it must not return into the caller's
    # code: every way out is exec or _exit.
    my $null = File::Spec->devnull();
    chdir $self->{root} or POSIX::_exit($EXEC_FAILED);
    open STDIN,  '<',  $null    or POSIX::_exit($EXEC_FAILED);
    open STDOUT, '>',  $null    or POSIX::_exit($EXEC_FAILED);
    open STDERR, '>&', \*STDOUT or POSIX::_exit($EXEC_FAILED);

    my @lib = map { File::Spec->rel2abs( $_, $self->{root} ) } @{ $self->{lib} };
    my $db  = File::Spec->catdir( $tmp, 'cover_db' );
    $ENV{PERL5LIB}                   = join $Config::Config{path_sep}, @lib, grep( { defined && length } $ENV{PERL5LIB} ), $OWN_LIB;
    $ENV{PERL5OPT}                   = join q{ }, $self->_cover_switch($db), '-MPerl::Tests::Covering::Recorder', grep { defined && length } $ENV{PERL5OPT};
    $ENV{PERL_TESTS_COVERING_LOADED} = $loaded;
    $ENV{HARNESS_ACTIVE}             = 1;

    # A list exec of perl itself, with no shell in between.
    { no warnings 'exec'; exec {$^X} $^X, $test }    ## no critic (ProhibitShellDispatch)
    POSIX::_exit($EXEC_FAILED);
}

# The -MDevel::Cover switch for one run.  Devel::Cover splits its options on
# commas, and perl splits PERL5OPT on whitespace, so either in the root is
# written as a \x escape, which the pattern still matches.  A relative name is
# relative to the root, where the run starts, and is sorted out from the rest
# in _files_in_run.
sub _cover_switch {
    my ( $self, $db ) = @_;

    ( my $root = quotemeta $self->{root} ) =~ s/\\([,\s])/sprintf '\\x%02x', ord $1/ge;
    Carp::croak("Cannot put a temporary directory with a comma or a space in it in PERL5OPT: $db") if $db =~ m/[,\s]/;
    return "-MDevel::Cover=-db,$db,-silent,1,-coverage,statement,-select,^(?!/)|^$root/";
}

# The record of one run: the digest of every file of the distribution that the
# test loaded, by what Devel::Cover and the recorder say, and of the test
# itself.
sub _record {
    my ( $self, $test, $tmp ) = @_;

    my %loaded = ( $test => 1 );
    $loaded{$_} = 1 for $self->_files_covered( File::Spec->catdir( $tmp, 'cover_db', 'runs' ) );
    $loaded{$_} = 1 for $self->_files_recorded( File::Spec->catdir( $tmp, 'loaded' ) );

    my %digests = map { $_ => $self->_digest($_) } keys %loaded;
    delete @digests{ grep { !defined $digests{$_} } keys %digests };
    return { loaded => \%digests };
}

# The files of the distribution in each run that Devel::Cover wrote.  It reads
# the counts of each run as loaded, because the public runs() goes through
# cover(), which also needs the working directory the run had.
sub _files_covered {
    my ( $self, $runs ) = @_;

    my @files;
    foreach my $dir ( _entries($runs) ) {
        my $db = eval { Devel::Cover::DB->new( db => $dir ) } or next;
        foreach my $run ( grep { ref eq 'HASH' } values %{ $db->{runs} // {} } ) {
            my $cwd = $run->{dir} // $self->{root};
            push @files, map { $self->_distribution_file( $_, $cwd ) } keys %{ $run->{count} // {} };
        }
    }
    return @files;
}

# The files of the distribution in each list that the recorder wrote.  A
# relative name in %INC is relative to wherever the require happened, which
# the recorder cannot know, so it is taken as relative to the root, where the
# run started.
sub _files_recorded {
    my ( $self, $loaded ) = @_;

    my @files;
    foreach my $list ( _entries($loaded) ) {
        my @names = eval { File::Slurper::read_lines($list) } or next;
        push @files, map { $self->_distribution_file( $_, $self->{root} ) } @names;
    }
    return @files;
}

# The paths in a directory, or none when it cannot be read.
sub _entries {
    my ($dir) = @_;

    opendir my $dh, $dir or return;
    my @entries = map { File::Spec->catfile( $dir, $_ ) } grep { !m/\A[.]/ } readdir $dh;
    closedir $dh;
    return @entries;
}

# $name, which a run loaded from $cwd, relative to the root, or nothing when it
# is not a file of the distribution.
sub _distribution_file {
    my ( $self, $name, $cwd ) = @_;

    my $rel = $self->_relative( $name, $cwd ) // return;

    # A test run after `make` loads the copy in blib.
    $rel =~ s{\Ablib/(?:lib|arch)/}{lib/} or $rel =~ s{\Ablib/script/}{bin/};
    my $path = File::Spec->catfile( $self->{root}, $rel );
    return -e $path && !-d _ ? $rel : ();
}

sub _cache_path {
    my ($self) = @_;
    return if !defined $self->{cache_dir};
    return File::Spec->catfile( $self->{cache_dir}, Digest::SHA::sha1_hex( $self->{root} ) . '.json.gz' );
}

# The format of the cache, the stamp of this file, the perl, and the
# configuration a run depends on.  Records made under another key are stale.
sub _cache_key {
    my ($self) = @_;

    my @st = stat __FILE__;
    return join q{/}, $CACHE_FORMAT, join( q{:}, @st[ 0, 1, 7, 9 ] ), $^X, $], join( q{,}, @{ $self->{tests} } ), join( q{,}, @{ $self->{lib} } );
}

# The records in the cache, keyed by test, or an empty hash.
sub _read_cache {
    my ($self) = @_;

    my $path = $self->_cache_path() or return {};

    # A cache that is not there fails to read, like one that is unreadable.
    my $cache = eval {
        my $gz = File::Slurper::read_binary($path);
        IO::Uncompress::Gunzip::gunzip( \$gz => \my $json ) or return;
        Cpanel::JSON::XS->new->decode($json);
    };
    return {} if ref $cache ne 'HASH' || ( $cache->{key} // q{} ) ne $self->_cache_key() || ref $cache->{tests} ne 'HASH';
    return $cache->{tests};
}

# Replaces the file whole, so a reader never sees half of it.
sub _write_cache {
    my ( $self, $records ) = @_;

    my $path = $self->_cache_path() or return;
    my $json = Cpanel::JSON::XS->new->canonical->encode( { key => $self->_cache_key(), root => $self->{root}, tests => $records } );

    # The root goes in the gzip header too, so that _prune_cache can read it
    # without decompressing the file.
    IO::Compress::Gzip::gzip( \$json => \my $gz, Comment => $self->{root} ) or return;

    File::Path::make_path( $self->{cache_dir}, { error => \my $errors } );
    return if @$errors;

    my $ok = eval { File::Slurper::Temp::write_binary( $path, $gz ); 1 };
    _prune_cache( $self->{cache_dir} ) if $ok;
    return $ok;
}

# Removes the cache of each root that is gone, such as a deleted checkout.  A
# file whose header cannot be read is removed too, since nothing can read it.
sub _prune_cache {
    my ($cache_dir) = @_;

    opendir( my $dh, $cache_dir ) or return;
    my @names = grep { m/$CACHE_FILE_RX/ } readdir $dh;
    closedir $dh;

    foreach my $name (@names) {
        my $file = File::Spec->catfile( $cache_dir, $name );
        my $root = _cached_root($file);
        next if defined $root && -d $root;
        unlink $file;
    }
    return;
}

# The root that a cache file is for, from its gzip header, or undef.
sub _cached_root {
    my ($file) = @_;

    my $z      = IO::Uncompress::Gunzip->new($file) or return;
    my $header = $z->getHeaderInfo();
    $z->close();
    return ref $header eq 'HASH' ? $header->{Comment} : undef;
}

=head1 SEE ALSO

tests-covering

Devel::Cover

Perl::Critic::Policy::ProhibitUnusedDefinitions

=cut

1;
