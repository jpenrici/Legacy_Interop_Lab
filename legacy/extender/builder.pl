#!/usr/bin/env perl
# legacy/extender/builder.pl

# TO DO - PDO

use strict;
use warnings;
use Cwd            qw(abs_path);
use File::Basename qw(dirname);
use File::Temp     qw(tempdir);

# --- paths -----------------------------------------------------------
my $here = abs_path( dirname(__FILE__) );
my $root = abs_path("$here/..");

# --- helper ----------------------------------------------------------
my $mode = shift // 'all';
die "usage: builder.pl [build|test|clean]\n"
  unless $mode =~ /^(all|build|test|clean)$/;

sub fail { print STDERR "builder: @_\n"; exit 1 }

# --- run -----------------------------------------------------------
sub run { print "builder: @_\n"; system(@_) == 0 or fail("failed: @_") }

# --- clean -----------------------------------------------------------
if ( $mode eq 'clean' ) {
    unlink "$root/bin/cpp_extender_test";
    print "builder: cleaned\n";
    exit 0;
}

# --- main ------------------------------------------------------------
# 1. the lib_c_api needs to exist.
fail("lib/lib_c_api not found - run: perl bridge/builder.pl")
  unless -x "$root/lib/lib_c_api.so";

if ( $mode ne 'test' ) {

    # 2. tools and GCC >= 14
    my ($cmake) = grep { -x $_ } map { "$_/cmake" } split /:/, $ENV{PATH} // '';
    fail("cmake not found") unless $cmake;

    my @cands = grep { defined && length } ( $ENV{CXX}, qw(g++-15 g++-14 g++) );
    my ( $cxx, $major );
    for my $c (@cands) {
        my $v = `$c -dumpversion 2>/dev/null` or next;
        ($major) = $v =~ /^(\d+)/ or next;
        if ( $major >= 14 ) { $cxx = $c; last }
    }
    fail("GCC >= 14 not found (tried: @cands); set CXX=/path/to/g++-14")
      unless $cxx;
    print "builder: using $cxx (GCC/G++$major)\n";

    # 3. out-of-tree build dir, removed afterwards
    my $build = tempdir( 'legacy_wrapper_XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    run( $cmake, '-S', $here, '-B', $build, "-DCMAKE_CXX_COMPILER=$cxx",
        '-DCMAKE_BUILD_TYPE=Release' );
    run( $cmake, '--build', $build, '-j' );
    print "builder: built lib/cpp_api.so and bin/cpp_extender_test\n";
}

# 4. tests always run from legacy/bin, like any other executable
if ( $mode ne 'build' ) {
    fail("bin/cpp_extender_test not found - run build first")
      unless -x "$root/bin/cpp_extender_test";
    chdir "$root/bin" or fail("chdir: $!");
    run('./cpp_extender_test');
}
