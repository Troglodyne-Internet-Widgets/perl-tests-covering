package Perl::Tests::Covering::Recorder;

# ABSTRACT: Writes down every file a perl loaded, as it exits.

use 5.014;

use strict;
use warnings FATAL => 'all';

=head1 DESCRIPTION

L<Perl::Tests::Covering> loads this into each coverage run through
C<PERL5OPT>, next to L<Devel::Cover>.  At C<END> it appends C<$0> and every
file in C<%INC> to a file named after the process id, in the directory named by
C<PERL_TESTS_COVERING_LOADED>.  Without that variable it does nothing.

It is there because Devel::Cover builds its record from the subs that exist
when the program ends.  The code at the top of a required file has been freed
by then.  So a module that is nothing but top-level code, such as one that
only sets a hash of configuration, is not in Devel::Cover's record at all.

It loads nothing but L<strict> and L<warnings>, so that the test sees the
C<%INC> it would see without it.

=cut

END {
    # Taken whole, which also untaints it for a test run under -T.
    my ($dir) = ( $ENV{PERL_TESTS_COVERING_LOADED} // q{} ) =~ m/\A(.+)\z/saa;
    if ( defined $dir && open my $fh, '>>', "$dir/loaded.$$" ) {
        print {$fh} map { "$_\n" } grep { defined && index( $_, "\n" ) < 0 } $0, values %INC;
        close $fh;
    }
}

1;
