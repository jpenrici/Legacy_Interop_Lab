#!/usr/bin/env perl
# legacy/bindings/freepascal/builder.pl

=head1 NAME

builder.pl - compile, test, and clean the FreePascal bindings for the legacy ledger

=head1 SYNOPSIS

  perl bindings/freepascal/builder.pl [all|build|test|clean]  (default: all)

  LEGACY_ALLOW_ROOT=1 perl bindings/freepascal/builder.pl

=head1 DESCRIPTION

The FreePascal bindings compile a native command-line test program that interfaces
with the C++ extender ABI (C<lib/lib_cpp_api.so>) using FPC.

=over 4

=item B<build>    compile test using fpc

=item B<test>     run the compiled test binary from legacy/bin

=item B<all>      build, then test

=item B<clean>    remove compilation artifacts

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

# Mode from the command line: all | build | test | clean.
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

    my $binary = "$ctx->{bin}/$ctx->{exe}";
    unlink $binary if -f $binary;

    remove_tree("$ctx->{here}/build") if -d "$ctx->{here}/build";

    print "builder: cleaned all build artifacts and binaries\n";
    return 0;
}

sub do_build {
    my ($ctx) = @_;
    chdir $ctx->{here} or fail("chdir $ctx->{here}: $!");

    my $build_dir = "$ctx->{here}/build";
    make_path($build_dir) unless -d $build_dir;

    # Compiles FreePascal, pointing to the C++ library at the root (lib/).
    run( $ctx->{fpc}, "-FE$ctx->{bin}", "-o$ctx->{exe}",
        "-FU$build_dir", '-Fusrc', '-Fl' . "$ctx->{lib}",
        "$ctx->{test}" );
    print
"builder: FreePascal test binary built successfully (artifacts isolated in build/)\n";
    return 0;
}

sub do_test {
    my ($ctx) = @_;
    my $binary = "$ctx->{bin}/$ctx->{exe}";
    -x $binary or fail("test binary not found - run build first");

    chdir "$ctx->{bin}" or fail("chdir $ctx->{bin}: $!");

    local $ENV{LD_LIBRARY_PATH} = "$ctx->{lib}";

    run($binary);
    return 1;
}

# ----------------------------------------------------- component specifics

sub build_context {
    my $here = abs_path( dirname(__FILE__) );
    my $root = abs_path("$here/../..");
    return {
        here   => $here,
        root   => $root,
        bin    => "$root/bin",
        lib    => "$root/lib",
        exe    => "freepascal_test",
        source => "$here/src/binding.pas",
        test   => "$here/tests/test_ledger.pas"
    };
}

sub check_prerequisites {
    my ( $ctx, $mode ) = @_;
    if ( $mode ne 'build' ) {
        require_artifact( $ctx->{lib}, 'lib_cpp_api.so',
            'perl extender/builder.pl' );
        require_artifact( $ctx->{bin}, 'cobol_app', 'perl cobol/builder.pl' );
    }
    -f $ctx->{source} or fail("missing $ctx->{source}");
    -f $ctx->{test}   or fail("missing $ctx->{source}");
    return 1;
}

sub find_toolchain {
    my ($ctx) = @_;
    my $fpc = find_in_path('fpc') || $ENV{FPC};
    if ( !$fpc || !-x $fpc ) {
        for my $candidate ( '/usr/bin/fpc', '/usr/bin/x86_64-linux-gnu-fpc' ) {
            if ( -x $candidate ) {
                $fpc = $candidate;
                last;
            }
        }
    }

    fail("fpc not found; apt install fpc") unless $fpc && valid_command($fpc);
    my ( $rc, $out ) = capture( $fpc, '-iV' );
    $rc == 0 or fail("fpc --version failed:\n$out");
    chomp $out;
    print "builder: using FreePascal compiler version $out ($fpc)\n";
    $ctx->{fpc} = $fpc;
    return 1;
}

# ---------------------------------------------------------------- shared

# BEGIN shared-builder-helpers
# Identical in every builder (cobol, bridge, extender): `setup.pl check`
# verifies it. Safe by construction: no shell, no root, no inherited flags.

sub fail { print STDERR "builder: @_\n"; exit 1 }

sub run {
    my @cmd = @_;
    print "builder: @cmd\n";
    system(@cmd) == 0 or fail("failed: @cmd");
    return 1;
}

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

sub require_unprivileged {
    return 1 if $> != 0;
    if ( ( $ENV{LEGACY_ALLOW_ROOT} // '' ) eq '1' ) {
        print STDERR "builder: WARNING running as root (LEGACY_ALLOW_ROOT=1)\n";
        return 1;
    }
    fail("refusing to run as root; use LEGACY_ALLOW_ROOT=1 to override");
}

sub scrub_environment {
    delete @ENV{
        qw(CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBRARY_PATH CPATH C_INCLUDE_PATH
          CPLUS_INCLUDE_PATH LD_PRELOAD COB_CFLAGS COB_LDFLAGS)
    };
    $ENV{LC_ALL} = 'C';
    umask 022;
    return 1;
}

sub valid_command {
    my ($cmd) = @_;
    return defined $cmd && $cmd =~ m{^[A-Za-z0-9_+./-]+$};
}

sub find_in_path {
    my ($name) = @_;
    for my $dir ( split /:/, $ENV{PATH} // '' ) {
        next                if $dir eq '';
        return "$dir/$name" if -f "$dir/$name" && -x _;
    }
    return;
}

sub require_artifact {
    my ( $root, $relative, $hint ) = @_;
    -e "$root/$relative" or fail("$relative not found - run: $hint");
    return 1;
}

# END shared-builder-helpers

# ------------------------------------------------------------------ go

exit main(@ARGV) unless caller;
1;
