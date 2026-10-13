#!/usr/bin/env perl
# legacy/bindings/rust/builder.pl

=head1 NAME

builder.pl - compile, test, and manage the Rust bindings for the legacy ledger

=head1 SYNOPSIS

  perl bindings/rust/builder.pl [all|build|test|clean]  (default: all)

  RUSTUP_HOME=/path perl bindings/rust/builder.pl
  LEGACY_ALLOW_ROOT=1 perl bindings/rust/builder.pl

=head1 DESCRIPTION

The Rust bindings use Cargo to build a native dynamic library that wraps
the C++ extender ABI (C<lib/lib_cpp_api.so>).

=over 4

=item B<build>    compile the Rust binding via cargo build --release

=item B<test>     run cargo test

=item B<all>      build, then test

=item B<clean>    clean cargo artifacts

=back

=head1 EXIT STATUS

0 success, 1 failure (message on stderr), 2 usage error.

=cut

use strict;
use warnings;
use Cwd            qw(abs_path);
use File::Basename qw(dirname basename);
use File::Path     qw(make_path remove_tree);

# ------------------------------------------------------------------ main

sub main {
    my $mode = parse_args(@_);
    require_unprivileged();
    scrub_environment();

    my $ctx = build_context();
    return do_clean($ctx) if $mode eq 'clean';

    check_prerequisites( $ctx, $mode );
    find_toolchain($ctx) if $mode =~ /^(?:all|build|test)$/;
    do_build($ctx)       if $mode =~ /^(?:all|build)$/;
    do_test($ctx)        if $mode =~ /^(?:all|test)$/;
    return 0;
}

sub parse_args {
    my @args = @_;
    my $mode = @args ? shift @args : 'all';
    return $mode if $mode =~ /^(?:all|build|test|clean)$/ && !@args;
    print STDERR "usage: builder.pl [all|build|test|clean]\n";
    exit 2;
}

# ----------------------------------------------------------------- modes

sub do_clean {
    my ($ctx) = @_;
    chdir $ctx->{here} or fail("chdir $ctx->{here}: $!");
    run( 'cargo', 'clean' );
    print "builder: cleaned\n";
    return 0;
}

sub do_build {
    my ($ctx) = @_;
    chdir $ctx->{here} or fail("chdir $ctx->{here}: $!");

    # Set the C++ shared library in the local LD_LIBRARY_PATH for the build
    local $ENV{LD_LIBRARY_PATH} = "$ctx->{root}/lib";

    run( 'cargo', 'build', '--release' );
    print "builder: Rust binding built successfully\n";
    return 0;
}

sub do_test {
    my ($ctx) = @_;
    chdir $ctx->{here} or fail("chdir $ctx->{here}: $!");

    local $ENV{LD_LIBRARY_PATH} = "$ctx->{root}/lib";

    return run( 'cargo', 'test', "--", "--nocapture" );
}

# ----------------------------------------------------- component specifics

sub build_context {
    my $here = abs_path( dirname(__FILE__) );
    my $root = abs_path("$here/../..");
    return {
        here  => $here,
        root  => $root,
        cargo => "$here/Cargo.toml",
    };
}

sub check_prerequisites {
    my ( $ctx, $mode ) = @_;
    if ( $mode ne 'build' ) {
        require_artifact( $ctx->{root}, 'lib/lib_cpp_api.so',
            'perl extender/builder.pl' );
        require_artifact( $ctx->{root}, 'bin/cobol_app',
            'perl cobol/builder.pl' );
    }
    -f $ctx->{cargo} or fail("missing $ctx->{cargo}");
    return 1;
}

sub find_toolchain {
    my ($ctx) = @_;
    my $cargo = find_in_path('cargo') || $ENV{CARGO};
    if ( !$cargo || ! -x $cargo ) {
        my $home = $ENV{HOME} || '';
        if ( -x "$home/.cargo/bin/cargo" ) {
            $cargo = "$home/.cargo/bin/cargo";
            $ENV{PATH} = "$home/.cargo/bin:" . ( $ENV{PATH} // '' );
        }
    }

    fail("cargo not found; install Rust (https://rustup.rs/)") unless $cargo && valid_command($cargo);
    my ( $rc, $out ) = capture( $cargo, '--version' );
    $rc == 0 or fail("cargo --version failed:\n$out");
    chomp $out;
    print "builder: using $out\n";
    return 1;
}

# ---------------------------------------------------------------- shared

# BEGIN shared-builder-helpers
# Identical in every builder (cobol, bridge, extender): `setup.pl check`
# verifies it. Safe by construction: no shell, no root, no inherited flags.

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
