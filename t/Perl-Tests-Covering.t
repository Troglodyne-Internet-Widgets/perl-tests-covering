#!/usr/bin/env perl

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Perl-Tests-Covering.t - which tests it reports, and when it runs one again

=head1 DESCRIPTION

Every case is a small distribution written to a temporary directory, with a
cache directory of its own.

The coverage run itself is mocked: C<_run_tests> answers from C<%LOADS>, a list
of what each test loads, instead of running the test.  So these cases are
about the records and the cache.  F<t/integration-Perl-Tests-Covering.t> runs
the tests under Devel::Cover for real.

=cut

# Both import by being loaded, which ProhibitUnusedImports cannot see.
use Test2::V1 -i;                 ## no critic (ProhibitUnusedImports)
use Test2::Plugin::NoWarnings;    ## no critic (ProhibitUnusedImports)
use Test2::Tools::Exception qw{dies lives};
use Test::MockModule        qw{strict};
use Cwd                     ();
use Digest::SHA             ();
use File::Path              qw{make_path};
use File::Spec              ();
use File::Temp              qw{tempdir};
use IO::Compress::Gzip      ();

use FindBin::libs;

use WriteFile qw{write_file};

use Perl::Tests::Covering ();

# What each test loads, besides itself, as the mocked coverage run reports it.
our %LOADS;

# The tests the mocked coverage run was asked to run, in order.
our @RAN;

my $mock = Test::MockModule->new('Perl::Tests::Covering');
$mock->redefine(
    _run_tests => sub {
        my ( $self, @tests ) = @_;
        push @RAN, @tests;
        return {
            map {
                $_ => { loaded => { map { $_ => sha1_of( $self->root(), $_ ) } grep { -e File::Spec->catfile( $self->root(), $_ ) } $_, @{ $LOADS{$_} // [] } } }
            } @tests
        };
    }
);

sub sha1_of {
    my ( $root, $rel ) = @_;
    return Digest::SHA->new(1)->addfile( File::Spec->catfile( $root, $rel ), 'b' )->hexdigest();
}

# A distribution: two modules, a script, and three tests.
sub dist {
    my $root = tempdir( CLEANUP => 1 );
    write_file( $root, 'dist.ini',          "name = Bogus\n" );
    write_file( $root, 'lib/Foo.pm',        "package Foo; 1;\n" );
    write_file( $root, 'lib/Bar.pm',        "package Bar; 1;\n" );
    write_file( $root, 'bin/foo',           "use Foo;\n" );
    write_file( $root, 't/a.t',             "use Foo;\n" );
    write_file( $root, 't/b.t',             "system 'bin/foo';\n" );
    write_file( $root, 't/deeper/c.t',      "use Bar;\n" );
    write_file( $root, 't/lib/Helper.pm',   "package Helper; 1;\n" );
    write_file( $root, 't/data/not-a-test', "1\n" );
    return Cwd::abs_path($root);
}

sub covering {
    my ( $root, %opts ) = @_;
    return Perl::Tests::Covering->new( root => $root, cache_dir => File::Spec->catdir( $root, '.cache-bogus' ), %opts );
}

# Runs $code with the current directory at $dir, and returns what it returns.
sub in_dir {
    my ( $dir, $code ) = @_;
    my $was = Cwd::getcwd();
    chdir $dir or die "Cannot chdir to $dir: $!";
    my @got = eval { $code->() };
    my $err = $@;
    chdir $was or die "Cannot chdir back to $was: $!";
    die $err if $err;
    return @got;
}

local %LOADS = (
    't/a.t'        => ['lib/Foo.pm'],
    't/b.t'        => [ 'bin/foo', 'lib/Foo.pm' ],
    't/deeper/c.t' => ['lib/Bar.pm'],
);

subtest new => sub {
    my $root = dist();

    like( dies { Perl::Tests::Covering->new( root => $root, bogus => 1 ) },         qr/Unknown option\(s\).*bogus/, 'An option it does not know is an error, not ignored' );
    like( dies { Perl::Tests::Covering->new( root => "$root/nonexistent-bogus" ) }, qr/No root/,                    'A root that does not exist is an error' );

    foreach my $jobs ( 0, -1, 'x', '1.5', q{} ) {
        like( dies { covering( $root, jobs => $jobs ) }, qr/jobs must be/, "jobs => '$jobs' is refused" );
    }
    ok( lives { covering( $root, jobs => 1 ) }, 'jobs => 1, the smallest, is accepted' ) or note($@);

    like( dies { covering( $root, tests => 't' ) },        qr/tests must be a list/, 'tests as one string, not a list, is refused' );
    like( dies { covering( $root, lib   => { a => 1 } ) }, qr/lib must be a list/,   'lib as a hash is refused' );

    my ($found) = in_dir( "$root/lib", sub { Perl::Tests::Covering->new( cache_dir => "$root/.cache-bogus" )->root() } );
    is( $found, $root, 'With no root, the nearest directory above with a dist.ini is the root' );

    my $bare = Cwd::abs_path( tempdir( CLEANUP => 1 ) );
  SKIP: {
        skip 'a directory above the temporary directory looks like a distribution', 1 if Perl::Tests::Covering::_find_root($bare);
        like(
            dies {
                in_dir( $bare, sub { Perl::Tests::Covering->new() } )
            },
            qr/No root: no distribution above/,
            'With no root and none above, it says so'
        );
    }
};

subtest root => sub {
    my $root = dist();
    my $link = File::Spec->catfile( tempdir( CLEANUP => 1 ), 'link-bogus' );
    symlink $root, $link or skip_all("Cannot symlink here: $!");

    is( covering($link)->root(), $root, 'A root reached by a symbolic link is the directory itself, so it has one cache' );
};

subtest tests => sub {
    my $root = dist();

    is( [ covering($root)->tests() ], [qw{t/a.t t/b.t t/deeper/c.t}], 'Every .t under t/, in subdirectories too, and nothing else' );

    write_file( $root, 'xt/author.t', "1;\n" );
    is( [ covering( $root, tests => [qw{t xt nonexistent-bogus}] )->tests() ], [qw{t/a.t t/b.t t/deeper/c.t xt/author.t}], 'tests names the directories, and one that is not there adds nothing' );
};

subtest refresh => sub {
    my $root = dist();

    local @RAN;
    is( [ covering($root)->refresh() ], [qw{t/a.t t/b.t t/deeper/c.t}], 'With no cache, every test runs' );
    ok( -d "$root/.cache-bogus", 'and the cache is written' );

    @RAN = ();
    is( [ covering($root)->refresh() ], [], 'A new object with the same cache runs nothing' );
    is( \@RAN,                          [], 'and asks for no coverage run' );

    write_file( $root, 't/a.t', "use Foo; 1;\n" );
    is( [ covering($root)->refresh() ], ['t/a.t'], 'A changed test runs again, and only it' );

    write_file( $root, 'lib/Foo.pm', "package Foo; our \$x = 1; 1;\n" );
    is( [ covering($root)->refresh() ], [qw{t/a.t t/b.t}], 'A changed module runs again each test that loaded it' );

    write_file( $root, 't/lib/Helper.pm', "package Helper; 2;\n" );
    is( [ covering($root)->refresh() ], [], 'A change to a file no test loaded runs nothing' );

    write_file( $root, 't/d.t', "1;\n" );
    is( [ covering($root)->refresh() ], ['t/d.t'], 'A new test runs' );

    unlink "$root/lib/Bar.pm" or die $!;
    is( [ covering($root)->refresh() ], ['t/deeper/c.t'], 'A test that loaded a file which is gone runs again' );

    is( [ covering( $root, lib => [qw{lib t/lib}] )->refresh() ], [qw{t/a.t t/b.t t/d.t t/deeper/c.t}], 'Other lib directories make every record stale' );
    is( [ covering($root)->refresh() ],                           [qw{t/a.t t/b.t t/d.t t/deeper/c.t}], 'and so does going back, since the cache holds one configuration' );

    my ($cache) = glob "$root/.cache-bogus/*.json.gz";
    write_file( $root, File::Spec->abs2rel( $cache, $root ), 'not gzip' );
    is( [ covering($root)->refresh() ], [qw{t/a.t t/b.t t/d.t t/deeper/c.t}], 'A cache that does not decompress is an empty one, not an error' );

    my $blocked = write_file( $root, 'cache-bogus-is-a-file', q{} );
    ok( lives { covering( $root, cache_dir => "$blocked/sub" )->refresh() }, 'A cache that cannot be written is not an error' ) or note($@);
};

subtest tests_covering => sub {
    my $root = dist();

    my $covering = covering($root);
    is( [ $covering->tests_covering("$root/lib/Foo.pm") ],                       [qw{t/a.t t/b.t}],              'A module is covered by each test that loads it, directly or through a script' );
    is( [ $covering->tests_covering("$root/bin/foo") ],                          ['t/b.t'],                      'A script is covered by the test that runs it' );
    is( [ $covering->tests_covering("$root/t/a.t") ],                            ['t/a.t'],                      'A test covers itself' );
    is( [ $covering->tests_covering( "$root/lib/Foo.pm", "$root/lib/Bar.pm" ) ], [qw{t/a.t t/b.t t/deeper/c.t}], 'Several files are covered by the tests of each, once' );
    is( [ $covering->tests_covering("$root/t/lib/Helper.pm") ],                  [],                             'A file no test loads is covered by nothing' );
    is( [ $covering->tests_covering('/bogus/lib/Foo.pm') ],                      [],                             'A file outside the root is covered by nothing' );
    is( [ $covering->tests_covering() ],                                         [],                             'No files, no tests' );

    is( [ in_dir( "$root/lib", sub { $covering->tests_covering('Foo.pm') } ) ], [qw{t/a.t t/b.t}], 'A relative file is relative to the current directory' );

    # c.t now loads Foo as well; its old record says it does not.
    local $LOADS{'t/deeper/c.t'} = [qw{lib/Bar.pm lib/Foo.pm}];
    write_file( $root, 't/deeper/c.t', "use Bar; use Foo;\n" );
    is( [ $covering->tests_covering("$root/lib/Foo.pm") ], [qw{t/a.t t/b.t t/deeper/c.t}], 'A test that loads the file only since it changed is reported' );

    # c.t no longer loads Bar; its old record says it does.
    local $LOADS{'t/deeper/c.t'} = ['lib/Foo.pm'];
    write_file( $root, 't/deeper/c.t', "use Foo;\n" );
    is( [ $covering->tests_covering("$root/lib/Bar.pm") ], ['t/deeper/c.t'], 'A test that loaded the file until it changed is reported' );

    unlink "$root/lib/Bar.pm" or die $!;
    is( [ covering($root)->tests_covering("$root/lib/Bar.pm") ], [], 'A deleted file nothing loaded any more is covered by nothing' );

    unlink "$root/t/b.t" or die $!;
    is( [ covering($root)->tests_covering("$root/bin/foo") ], [], 'A test that is gone is not reported, although its old record covers the file' );
};

subtest 'tests_covering the deletion of a module' => sub {
    my $root = dist();
    covering($root)->refresh();

    unlink "$root/lib/Foo.pm" or die $!;
    local $LOADS{'t/a.t'} = [];
    local $LOADS{'t/b.t'} = ['bin/foo'];
    is( [ covering($root)->tests_covering("$root/lib/Foo.pm") ], [qw{t/a.t t/b.t}], 'A deleted module is covered by the tests that loaded it, which are the ones it breaks' );
};

subtest _prune_cache => sub {
    my $root  = dist();
    my $cache = "$root/.cache-bogus";
    covering($root)->refresh();
    my ($ours) = glob "$cache/*.json.gz";

    my $gone = 'a' x 40;
    IO::Compress::Gzip::gzip( \'{}' => "$cache/$gone.json.gz", Comment => '/nonexistent-bogus' ) or die;
    write_file( $root, ".cache-bogus/${\( 'b' x 40 )}.json.gz", 'not gzip' );
    write_file( $root, '.cache-bogus/somebody-elses',           'keep' );

    Perl::Tests::Covering::_prune_cache($cache);
    ok( -e $ours,                              'The cache of a root that is there is kept' );
    ok( !-e "$cache/$gone.json.gz",            'The cache of a root that is gone is removed' );
    ok( !-e "$cache/${\( 'b' x 40 )}.json.gz", 'A cache whose header cannot be read is removed' );
    ok( -e "$cache/somebody-elses",            'A file that is not a cache is left alone' );
};

subtest _cover_switch => sub {
    my $root = tempdir( CLEANUP => 1 );
    my $odd  = "$root/a, b";
    make_path( "$odd/t", "$odd/lib" );
    write_file( $odd, 'dist.ini', q{} );

    my $switch = covering($odd)->_cover_switch('/bogus/db');
    unlike( $switch, qr/[\s]/, 'No whitespace in the switch, since perl splits PERL5OPT on it' );
    my ($opts) = $switch =~ m/\A-MDevel::Cover=(.*)\z/ or die "Not a Devel::Cover switch: $switch";
    my %opts   = split q{,}, $opts;
    is( $opts{-db}, '/bogus/db', 'Splitting on commas finds the database whole' );

    my $select = qr/$opts{-select}/;
    my $real   = Cwd::abs_path($odd);
    like( "$real/lib/Foo.pm", $select, 'The pattern selects a file under a root with a comma and a space in it' );
    like( 'lib/Foo.pm',       $select, 'and a relative one' );
    unlike( '/bogus/lib/Foo.pm', $select, 'but not one under some other root' );

    like( dies { covering($odd)->_cover_switch('/bogus/a,b') }, qr/comma or a space/, 'A database directory with a comma in it is refused, not mangled' );
};

done_testing();
