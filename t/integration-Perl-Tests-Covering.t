#!/usr/bin/env perl

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/integration-Perl-Tests-Covering.t - what Devel::Cover says each test loads

=head1 DESCRIPTION

The tests of a small distribution really run under Devel::Cover here, in child
perls, so this is where a change in what Devel::Cover records shows up.  That
is slow next to the rest, so it runs only with C<RELEASE_TESTING=1>.

=cut

# Both import by being loaded, which ProhibitUnusedImports cannot see.
use Test2::V1 -i;                 ## no critic (ProhibitUnusedImports)
use Test2::Plugin::NoWarnings;    ## no critic (ProhibitUnusedImports)
use Capture::Tiny qw{capture};
use Cwd           ();
use File::Spec    ();
use File::Temp    qw{tempdir};

use FindBin::libs;

use WriteFile qw{write_file};

skip_all('Set RELEASE_TESTING=1 to run the tests of a distribution under Devel::Cover') if !$ENV{RELEASE_TESTING};

use Perl::Tests::Covering ();

# Tests that load a module, one that runs a script in a child perl, one that
# finds its lib by FindBin, and one that fails loudly.
my $root = Cwd::abs_path( tempdir( CLEANUP => 1 ) );
write_file( $root, 'dist.ini',               "name = Bogus\n" );
write_file( $root, 'lib/Foo.pm',             "package Foo;\nsub a { 1 }\nsub b { 2 }\n1;\n" );
write_file( $root, 'lib/Foo/NeverCalled.pm', "package Foo::NeverCalled;\nsub x { 1 }\n1;\n" );
write_file( $root, 'lib/Bar.pm',             "package Bar;\nsub c { 3 }\n1;\n" );
write_file( $root, 'lib/Unloaded.pm',        "package Unloaded;\n1;\n" );
write_file( $root, 'bin/foo',                "use Foo;\nprint Foo::b(), qq{\\n};\n" );
write_file( $root, 't/lib/Helper.pm',        "package Helper;\nsub h { 1 }\n1;\n" );
write_file( $root, 't/a.t',                  "use Test::More;\nuse Foo;\nuse Foo::NeverCalled;\nok( Foo::a() );\ndone_testing;\n" );
write_file( $root, 't/b.t',                  "use Test::More;\nmy \$out = `\$^X bin/foo`;\nis( \$out, qq{2\\n} );\ndone_testing;\n" );
write_file( $root, 't/c.t',                  "use Test::More;\nuse FindBin;\nuse lib qq{\$FindBin::Bin/../lib}, qq{\$FindBin::Bin/lib};\nuse Bar;\nuse Helper;\nok( Bar::c() && Helper::h() );\ndone_testing;\n" );
write_file( $root, 't/loud.t',               "print qq{not ok 1 - leaked\\n};\nprint STDERR qq{leaked\\n};\ndie qq{on purpose\\n};\n" );

my %cover = ( root => $root, cache_dir => File::Spec->catdir( $root, '.cache-bogus' ) );

subtest 'tests_covering, from real coverage runs' => sub {
    my $covering = Perl::Tests::Covering->new( %cover, jobs => 2 );

    my ( $out, $err, @ran ) = capture { $covering->refresh() };
    is( \@ran, [qw{t/a.t t/b.t t/c.t t/loud.t}], 'Every test runs the first time, two at once' );
    is( $out,  q{},                              'Nothing a test prints reaches STDOUT' );
    is( $err,  q{},                              'or STDERR' );

    is( [ $covering->tests_covering("$root/lib/Foo.pm") ],             [qw{t/a.t t/b.t}], 'A module is covered by the test that calls it and by the test whose child perl does' );
    is( [ $covering->tests_covering("$root/lib/Foo/NeverCalled.pm") ], ['t/a.t'],         'A module that is loaded but never called is covered' );
    is( [ $covering->tests_covering("$root/bin/foo") ],                ['t/b.t'],         'A script is covered by the test that runs it in a child perl' );
    is( [ $covering->tests_covering("$root/lib/Bar.pm") ],             ['t/c.t'],         'A module found through FindBin, by an absolute path, is covered' );
    is( [ $covering->tests_covering("$root/t/lib/Helper.pm") ],        ['t/c.t'],         'A test helper is covered' );
    is( [ $covering->tests_covering("$root/t/loud.t") ],               ['t/loud.t'],      'A test that dies still covers itself' );
    is( [ $covering->tests_covering("$root/lib/Unloaded.pm") ],        [],                'A module no test loads is covered by nothing' );

    ok( !-e "$root/cover_db", 'Nothing is written to the cover_db of the distribution' );
};

subtest 'refresh, from real coverage runs' => sub {
    is( [ Perl::Tests::Covering->new(%cover)->refresh() ], [], 'A second object runs nothing' );

    write_file( $root, 'lib/Bar.pm', "package Bar;\nuse Unloaded;\nsub c { 3 }\n1;\n" );
    my $covering = Perl::Tests::Covering->new(%cover);
    is( [ $covering->tests_covering("$root/lib/Unloaded.pm") ], ['t/c.t'], 'A module that a changed module starts to load is covered after the one test runs again' );
};

done_testing();
