#!/usr/bin/env perl
# legacy/extender/builder.pl

=head1 NAME

builder.pl - build and test the C++23 extender, C<lib/lib_cpp_api.so>

=head1 SYNOPSIS

  perl extender/builder.pl [all|build|test|clean]     (default: all)

  CXX=g++-14 perl extender/builder.pl

=head1 DESCRIPTION

Builds, from C<extender/> into the portable part of the tree:

  lib/lib_cpp_api.so   C ABI (lgx_*) for bindings
  bin/extender_test    tests of the C++ core and of the C ABI

and runs the tests from C<legacy/bin>, like any other executable.

Requires C<lib/lib_c_api.so> (C<perl bridge/builder.pl>), C<bin/cobol_app> to
run the tests (C<perl cobol/builder.pl>), CMake 3.25 or newer and B<g++ 14 or
newer>. The compiler is taken from C<$CXX>, else C<g++-15>, C<g++-14>, C<g++>.
The CMake build directory is temporary and removed afterwards.

=over 4

=item B<build>  configure and compile only

=item B<test>   run bin/cpp_extender_test (must be built)

=item B<all>    build, then test

=item B<clean>  remove the two files above (data is never touched)

=back

=head1 ENVIRONMENT

  CXX=g++-14                the C++ compiler (GCC >= 14)
  LEGACY_ALLOW_ROOT=1       allow running as root (refused by default)

Compiler flags and library paths inherited from the caller are discarded.

=head1 EXIT STATUS

0 success, 1 failure (message on stderr), 2 usage error.

=cut

use strict;
use warnings;
use Cwd            qw(abs_path);
use File::Basename qw(dirname basename);
use File::Copy     qw(copy);
use File::Path     qw(make_path);
use File::Temp     qw(tempdir);

# ------------------------------------------------------------------ main

sub main {
    my $mode = parse_args(@_);
    require_unprivileged();
    scrub_environment();

    my $ctx = build_context();
    return do_clean($ctx) if $mode eq 'clean';

    check_prerequisites( $ctx, $mode );
    find_toolchain($ctx) if $mode ne 'test';
    do_build($ctx)       if $mode ne 'test';
    do_test($ctx)        if $mode ne 'build';
    return 0;
}

# ----------------------------------------------------------------- modes

sub do_clean {
    my ($ctx) = @_;
    unlink $ctx->{test}, $ctx->{library};
    print "builder: cleaned\n";
    return 0;
}

sub do_build {
    my ($ctx) = @_;
    cmake_build(
        source  => $ctx->{here},
        prefix  => 'extender',
        cmake   => $ctx->{cmake},
        defines => { CMAKE_CXX_COMPILER => $ctx->{cxx} },
    );
    print
"builder: built lib/lib_cpp_api.so and bin/extender_test\n";
    return 0;
}

sub do_test {
    my ($ctx) = @_;
    return run_test_binary( $ctx->{root}, 'cpp_extender_test' );
}

# ----------------------------------------------------- component specifics

sub build_context {
    my $here = abs_path( dirname(__FILE__) );
    my $root = abs_path("$here/..");
    return {
        here    => $here,
        root    => $root,
        bin     => "$root/bin",
        lib     => "$root/lib",
        test    => "$root/bin/extender_test",
        library => "$root/lib/lib_cpp_api.so",
    };
}

# Building needs the C bridge; the tests also run the COBOL executable.
sub check_prerequisites {
    my ( $ctx, $mode ) = @_;
    require_artifact( $ctx->{root}, 'lib/lib_c_api.so',
        'perl bridge/builder.pl' );
    require_artifact( $ctx->{root}, 'bin/cobol_app', 'perl cobol/builder.pl' )
      if $mode ne 'build';
    return 1 if $mode eq 'test';
    return ensure_writable_dirs( $ctx->{bin}, $ctx->{lib} );
}

# cmake, and a g++ >= 14.
sub find_toolchain {
    my ($ctx) = @_;
    $ctx->{cmake} = find_in_path('cmake') or fail('cmake not found');

    my @candidates =
      grep { defined && length } ( $ENV{CXX}, qw(g++-15 g++-14 g++) );
    my ( $cxx, $major ) = pick_compiler( 14, @candidates );
    fail(   'g++ >= 14 not found (tried: '
          . join( ' ', @candidates )
          . '); apt install g++-14 or set CXX=/path/to/g++-14' )
      unless $cxx;
    print "builder: using $cxx (GCC $major)\n";
    $ctx->{cxx} = $cxx;
    return 1;
}

# ---------------------------------------------------------------- shared

# BEGIN shared-builder-helpers
# Identical in every builder (cobol, bridge, extender): `setup.pl check`
# verifies it. Safe by construction: no shell, no root, no inherited flags.

# Mode from the command line: all | build | test | clean.
sub parse_args {
    my @args = @_;
    my $mode = @args ? shift @args : 'all';
    return $mode if $mode =~ /^(?:all|build|test|clean)$/ && !@args;
    print STDERR "usage: builder.pl [all|build|test|clean]\n";
    exit 2;
}

sub fail { print STDERR "builder: @_\n"; exit 1 }

# Runs a command in list form (never through a shell); a failure stops the build.
sub run {
    my @cmd = @_;
    print "builder: @cmd\n";
    system(@cmd) == 0 or fail("failed: @cmd");
    return 1;
}

# Output of a command (stdout and stderr merged) and its exit code. List form.
sub capture {
    my @cmd = @_;
    my $pid = open( my $fh, '-|' ) // fail("cannot fork: $!");
    if ( !$pid ) {
        open( STDERR, '>&', \*STDOUT );
        exec { $cmd[0] } @cmd or exit 127;
    }
    local $/;
    my $out = <$fh>;
    close $fh;
    return ( $? >> 8, $out // '' );
}

# Build outputs must not end up owned by root: a normal user could no longer
# rebuild or clean them. Nothing here ever needs privileges.
sub require_unprivileged {
    return 1 if $> != 0;
    if ( ( $ENV{LEGACY_ALLOW_ROOT} // '' ) eq '1' ) {
        print STDERR
"builder: WARNING running as root (LEGACY_ALLOW_ROOT=1): the files will be owned by root\n";
        return 1;
    }
    fail(   "refusing to run as root: the files would be owned by root.\n"
          . "builder: run as a normal user; no privilege is needed (LEGACY_ALLOW_ROOT=1 overrides, e.g. in a throw-away container)"
    );
}

# Same inputs, same build: nothing inherited from the caller may change it.
sub scrub_environment {
    delete @ENV{
        qw(CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBRARY_PATH CPATH C_INCLUDE_PATH
          CPLUS_INCLUDE_PATH LD_LIBRARY_PATH LD_PRELOAD COB_CFLAGS COB_LDFLAGS)
    };
    $ENV{LC_ALL} = 'C';
    umask 022;
    return 1;
}

# A command taken from the environment (CC, CXX, COBC...): plain characters only.
sub valid_command {
    my ($cmd) = @_;
    return defined $cmd && $cmd =~ m{^[A-Za-z0-9_+./-]+$};
}

# Full path of an executable found in PATH, or undef.
sub find_in_path {
    my ($name) = @_;
    for my $dir ( split /:/, $ENV{PATH} // '' ) {
        next                if $dir eq '';
        return "$dir/$name" if -f "$dir/$name" && -x _;
    }
    return;
}

# Major version of a GCC command, or undef.
sub compiler_major {
    my ($cmd) = @_;
    return unless valid_command($cmd);
    my ( $rc, $out ) = capture( $cmd, '-dumpversion' );
    return ( $rc == 0 && $out =~ /^(\d+)/ ) ? $1 : undef;
}

# First candidate that is a GCC of at least $min: ($command, $major), or ().
sub pick_compiler {
    my ( $min, @candidates ) = @_;
    for my $cmd ( grep { defined && length } @candidates ) {
        my $major = compiler_major($cmd) or next;
        return ( $cmd, $major ) if $major >= $min;
    }
    return;
}

# Creates the directories a build writes to and checks they are writable.
sub ensure_writable_dirs {
    my @dirs = @_;
    make_path(@dirs);
    for my $dir (@dirs) {
        -d $dir && -w $dir
          or fail(
            "$dir is not writable by this user; fix the ownership of the tree");
    }
    return 1;
}

# An artifact another component must have produced first.
sub require_artifact {
    my ( $root, $relative, $hint ) = @_;
    -e "$root/$relative" or fail("$relative not found - run: $hint");
    return 1;
}

# Out-of-tree CMake build in a private temporary directory, removed afterwards.
sub cmake_build {
    my (%a)     = @_;    # source, prefix, cmake, defines => { NAME => value }
    my $build   = tempdir( "$a{prefix}_XXXXXX", TMPDIR => 1, CLEANUP => 1 );
    my @defines = map { "-D$_=$a{defines}{$_}" } sort keys %{ $a{defines} };
    run( $a{cmake}, '-S', $a{source}, '-B', $build, @defines,
        '-DCMAKE_BUILD_TYPE=Release' );
    run( $a{cmake}, '--build', $build, '-j' );
    return 1;
}

# Runs ./NAME from legacy/bin, like any user would.
sub run_test_binary {
    my ( $root, $name ) = @_;
    -x "$root/bin/$name" or fail("bin/$name not found - run the build first");
    chdir "$root/bin"    or fail("chdir $root/bin: $!");
    return run("./$name");
}

# END shared-builder-helpers

# ------------------------------------------------------------------ go

exit main(@ARGV) unless caller;
1;
