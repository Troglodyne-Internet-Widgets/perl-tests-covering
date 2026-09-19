#!/usr/bin/env perl

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/tests-covering.t - what the command passes on, and what it prints

=head1 DESCRIPTION

L<Perl::Tests::Covering> is mocked here: C<new> records its options, and
C<tests_covering> answers from a fixed list, so no test runs under coverage.

=cut

# Both import by being loaded, which ProhibitUnusedImports cannot see.
use Test2::V1 -i;                 ## no critic (ProhibitUnusedImports)
use Test2::Plugin::NoWarnings;    ## no critic (ProhibitUnusedImports)
use Test2::Tools::Exception qw{lives};
use Test2::Tools::Warnings  qw{warnings};
use Test::MockModule        qw{strict};
use Capture::Tiny           qw{capture};
use Cwd                     ();
use File::Temp              qw{tempdir};

use FindBin::libs;
use FindBin ();

ok( lives { require "$FindBin::Bin/../bin/tests-covering" }, "bin/tests-covering loads as a module" ) or bail_out("bin/tests-covering does not load: $@");

my $root = Cwd::abs_path( tempdir( CLEANUP => 1 ) );
mkdir "$root/t" or die $!;

my ( @new_opts, @asked );
my $mock = Test::MockModule->new('Perl::Tests::Covering');
$mock->redefine(
    new => sub {
        my ( $class, %opts ) = @_;
        push @new_opts, \%opts;
        return $mock->original('new')->( $class, root => $root, cache_dir => "$root/.cache-bogus" );
    }
);
$mock->redefine(
    tests_covering => sub {
        my ( $self, @files ) = @_;
        push @asked, @files;
        return qw{t/a.t t/deeper/b.t};
    }
);

# main(@argv), with STDIN reading $stdin, run from $dir.  Returns the exit code,
# what it printed and what it warned.
sub run_main {
    my ( $dir, $stdin, @argv ) = @_;

    open my $in, '<', \$stdin or die $!;
    local *STDIN = $in;
    my $was = Cwd::getcwd();
    chdir $dir or die "Cannot chdir to $dir: $!";
    my $code;
    my ( $out, $err ) = capture { $code = Perl::Tests::Covering::Script::main(@argv) };
    chdir $was or die $!;
    return ( $code, $out, $err );
}

subtest main => sub {
    @new_opts = @asked = ();
    my ( $code, $out ) = run_main( $root, q{}, qw{lib/Foo.pm bin/foo} );
    is( $code,        0,                        'It exits 0 with an answer' );
    is( $out,         "t/a.t\nt/deeper/b.t\n",  'and prints each test, one per line' );
    is( \@asked,      [qw{lib/Foo.pm bin/foo}], 'The files on the command line are the ones asked about' );
    is( $new_opts[0], {},                       'With no options, the module picks every default' );

    @asked = ();
    ( $code, $out ) = run_main( "$root/t", "lib/Foo.pm\r\n\nbin/foo\n" );
    is( \@asked, [qw{lib/Foo.pm bin/foo}], 'With no files named, they are read from STDIN, without blank lines or line ends' );
    is( $out,    "a.t\ndeeper/b.t\n",      'The tests printed are relative to the current directory' );

    @new_opts = ();
    run_main( $root, q{}, qw{--root /bogus/root --test-dir t --test-dir xt --lib lib --lib t/lib --jobs 4 --cache-dir /bogus/cache x} );
    is(
        $new_opts[0],
        { root => '/bogus/root', tests => [qw{t xt}], lib => [qw{lib t/lib}], jobs => 4, cache_dir => '/bogus/cache' },
        'Each option reaches the module under its own name'
    );

    my ( $bad, $bad_out, $bad_err );
    my $warnings = warnings { ( $bad, $bad_out, $bad_err ) = run_main( $root, q{}, qw{--bogus} ) };
    like( $warnings, [qr/Unknown option: bogus/], 'An option it does not know is named in a warning' );
    is( $bad,     2,   'and exits 2' );
    is( $bad_out, q{}, 'and prints nothing where the tests would go' );
    like( $bad_err, qr/tests-covering \[options\] FILE/, 'but prints the synopsis to STDERR' );

    my ( $help, $help_out ) = run_main( $root, q{}, qw{--help} );
    is( $help, 0, '--help exits 0' );
    like( $help_out, qr/--cache-dir DIR/, 'and prints the options to STDOUT' );
};

subtest read_names => sub {
    open my $fh, '<', \"a\nb\r\n\n\nc" or die $!;
    is( [ Perl::Tests::Covering::Script::read_names($fh) ], [qw{a b c}], 'One name a line, with the line end and the blank lines dropped' );
};

done_testing();
