#!/usr/bin/env perl
# legacy/extender/builder.pl

=head1 NAME

builder.pl - build and test the C++23 extender

=head1 SYNOPSIS

  perl extender/builder.pl [all|build|test|clean]     (default: all)

  CXX=g++-14 perl extender/builder.pl                 choose the C++ compiler

=head1 DESCRIPTION

Builds, from C<extender/> into the portable part of the tree:

  lib/lib_cpp_api.so   C ABI (lgx_*) for bindings
  bin/cpp_extender_test     tests of the C++ core and of the C ABI

and runs the tests from C<legacy/bin>, like any other executable.

Requires C<lib/lib_c_api.so> (C<perl bridge/builder.pl>), and C<bin/cobol_app>
(C<perl cobol/builder.pl>) to run the tests, CMake 3.25 or newer and B<g++ 14 or
newer>. The C++ compiler is taken from C<$CXX>, else C<g++-15>, C<g++-14>,
C<g++>. The CMake build directory is temporary and removed afterwards.

=over 4

=item B<build>  configure and compile only

=item B<test>   run bin/cpp_extender_test (must be built)

=item B<all>    build, then test

=item B<clean>  remove the two files above (data is never touched)

=back

=head1 EXIT STATUS

0 success, 1 failure (message on stderr).

=cut

use strict;
use warnings;
use Cwd            qw(abs_path);
use File::Basename qw(dirname);
use File::Temp     qw(tempdir);

# --- paths -----------------------------------------------------------
my $here = abs_path( dirname(__FILE__) );
my $root = abs_path("$here/..");
my $test = "$root/bin/cpp_extender_test";
my $lib  = "$root/lib/lib_cpp_api.so";

# --- helpers ---------------------------------------------------------
my $mode = shift // 'all';
die "usage: builder.pl [all|build|test|clean]\n"
  unless $mode =~ /^(all|build|test|clean)$/;

sub fail { print STDERR "builder: @_\n"; exit 1 }
sub run  { print "builder: @_\n"; system(@_) == 0 or fail("failed: @_") }

# Major version of a GCC command, or undef. List-form exec: the command name
# (possibly from $CXX) never goes through a shell.
sub major_version {
    my ($cmd) = @_;
    my $pid = open( my $fh, '-|' ) // return;
    if ( !$pid ) {
        open( STDERR, '>', '/dev/null' );
        exec { $cmd } $cmd, '-dumpversion' or exit 127;
    }
    my $line = <$fh>;
    close $fh;
    return ( $line // '' ) =~ /^(\d+)/ ? $1 : undef;
}

# --- clean -----------------------------------------------------------
if ( $mode eq 'clean' ) {
    unlink $test, $lib;
    print "builder: cleaned\n";
    exit 0;
}

# --- main ------------------------------------------------------------
# 1. the C bridge must exist
fail("lib/lib_c_api.so not found - run: perl bridge/builder.pl")
  unless -f "$root/lib/lib_c_api.so";

if ( $mode ne 'test' ) {

    # 2. CMake and g++ >= 14
    my ($cmake) = grep { -x $_ } map { "$_/cmake" } split /:/, $ENV{PATH} // '';
    fail("cmake not found") unless $cmake;

    my @cands = grep { defined && length } ( $ENV{CXX}, qw(g++-15 g++-14 g++) );
    my ( $cxx, $major );
    for my $c (@cands) {
        my $v = major_version($c) or next;
        if ( $v >= 14 ) { ( $cxx, $major ) = ( $c, $v ); last }
    }
    fail("g++ >= 14 not found (tried: @cands); apt install g++-14 or set CXX=/path/to/g++-14")
      unless $cxx;
    print "builder: using $cxx (GCC $major)\n";

    # 3. out-of-tree build dir, removed afterwards
    my $build = tempdir( 'legacy_extender_XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    run( $cmake, '-S', $here, '-B', $build, "-DCMAKE_CXX_COMPILER=$cxx",
        '-DCMAKE_BUILD_TYPE=Release' );
    run( $cmake, '--build', $build, '-j' );
    print "builder: built lib/lib_cpp_api.so and bin/cpp_extender_test\n";
}

# 4. tests always run from legacy/bin, like any other executable
if ( $mode ne 'build' ) {
    fail("bin/cpp_extender_test not found - run build first") unless -x $test;
    fail("bin/cobol_app not found - run: perl cobol/builder.pl")
      unless -x "$root/bin/cobol_app";
    chdir "$root/bin" or fail("chdir: $!");
    run('./cpp_extender_test');
}
