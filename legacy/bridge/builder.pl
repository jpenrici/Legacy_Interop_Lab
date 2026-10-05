#!/usr/bin/env perl
# bridge/builder.pl - builds legacy/lib/lib_c_api.so and legacy/bin/c_api_test
#
# Requires: legacy/bin/legacy_app (run cobol/builder.pl first),
#           CMake >= 3.16 and GCC >= 14 (CC=/path/to/gcc-14 to choose one).
# Usage:    perl builder.pl [build|test|clean]     (default: build + test)
use strict;
use warnings;
use Cwd            qw(abs_path);
use File::Basename qw(dirname);
use File::Temp     qw(tempdir);

my $here = abs_path( dirname(__FILE__) );
my $root = abs_path("$here/..");
my $mode = shift // 'all';
die "usage: builder.pl [build|test|clean]\n"
  unless $mode =~ /^(all|build|test|clean)$/;

sub fail { print STDERR "builder: @_\n"; exit 1 }
sub run  { print "builder: @_\n";        system(@_) == 0 or fail("failed: @_") }

if ( $mode eq 'clean' ) {
    unlink "$root/bin/c_api_test", "$root/lib/lib_c_api.so";
    print "builder: cleaned\n";
    exit 0;
}

# 1. the COBOL executable must exist: the bridge drives it
fail("bin/legacy_app not found - run: perl cobol/builder.pl")
  unless -x "$root/bin/legacy_app";

if ( $mode ne 'test' ) {

    # 2. tools and GCC >= 14
    my ($cmake) = grep { -x $_ } map { "$_/cmake" } split /:/, $ENV{PATH} // '';
    fail("cmake not found") unless $cmake;

    my @cands = grep { defined && length } ( $ENV{CC}, qw(gcc-15 gcc-14 gcc) );
    my ( $cc, $major );
    for my $c (@cands) {
        my $v = `$c -dumpversion 2>/dev/null` or next;
        ($major) = $v =~ /^(\d+)/ or next;
        if ( $major >= 14 ) { $cc = $c; last }
    }
    fail("GCC >= 14 not found (tried: @cands); set CC=/path/to/gcc-14")
      unless $cc;
    print "builder: using $cc (GCC $major)\n";

    # 3. out-of-tree build dir, removed afterwards
    my $build = tempdir( 'legacy_bridge_XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    run( $cmake, '-S', $here, '-B', $build, "-DCMAKE_C_COMPILER=$cc",
        '-DCMAKE_BUILD_TYPE=Release' );
    run( $cmake, '--build', $build, '-j' );
    print "builder: built lib/lib_c_api.so and bin/c_api_test\n";
}

# 4. tests always run from legacy/bin, like any other executable
if ( $mode ne 'build' ) {
    fail("bin/c_api_test not found - run build first")
      unless -x "$root/bin/c_api_test";
    chdir "$root/bin" or fail("chdir: $!");
    run('./c_api_test');
}
