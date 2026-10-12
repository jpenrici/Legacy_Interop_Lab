#!/usr/bin/env perl
# legacy/bindings/python/builder.pl

=head1 NAME

builder.pl - prepare the Python venv for the bindings, and test them

=head1 SYNOPSIS

  perl bindings/python/builder.pl [all|build|test|clean|example]  (default: all)

  PYTHON=python3.12 perl bindings/python/builder.pl
  LEGACY_NO_QT=1    perl bindings/python/builder.pl          # without PySide6

=head1 DESCRIPTION

The bindings are plain Python (ctypes over C<lib/lib_cpp_api.so>): there
is nothing to compile. What this builder prepares is a B<virtual environment>,
so that PySide6 can be downloaded without touching the system Python:

  bindings/python/.venv/        the venv (not portable: regenerate, do not copy)
    lib/pythonX.Y/site-packages/legacy_ledger.pth
                                points at bindings/python/src, so the package is
                                importable from the venv and edits show up at once
                                (this is what an "editable install" does)
    PySide6-Essentials          from requirements-qt.txt (wheels only, ~85 MB)

The portable part of the tree (C<bin/>, C<lib/>, C<data/>) is never touched: the
venv lives next to the sources. Everything pip installs goes into the venv:
C<PIP_REQUIRE_VIRTUALENV> makes pip refuse to install anywhere else.

=over 4

=item B<build>    create the venv, link the sources, install PySide6, check the import

=item B<test>     run the unittest suite from legacy/bin (needs the extender and COBOL built)

=item B<all>      build, then test

=item B<clean>    remove the venv (sources and data are never touched)

=item B<example>  run the GUI example (needs the extender and COBOL built)

=back

=head1 ENVIRONMENT

  PYTHON=python3.12         the interpreter (3.10 or newer, with venv)
  LEGACY_NO_QT=1            do not install PySide6 (offline); the Qt tests are skipped
  LEGACY_ALLOW_ROOT=1       allow running as root (refused by default)

C<PYTHONPATH>, C<PYTHONHOME>, the user site and compiler flags inherited from
the caller are discarded; pip settings (index, proxy) are kept.

=head1 EXIT STATUS

0 success, 1 failure (message on stderr), 2 usage error.

=cut

use strict;
use warnings;
use Cwd            qw(abs_path);
use File::Basename qw(dirname basename);
use File::Copy     qw(copy);
use File::Path     qw(make_path remove_tree);
use File::Temp     qw(tempdir);

# ------------------------------------------------------------------ main

sub main {
    my $mode = parse_args(@_);
    require_unprivileged();
    scrub_environment();

    my $ctx = build_context();
    return do_clean($ctx) if $mode eq 'clean';

    check_prerequisites( $ctx, $mode );
    find_toolchain($ctx) if $mode eq 'build';
    do_build($ctx)       if $mode eq 'build';
    do_test($ctx)        if $mode eq 'test';
    do_example($ctx)     if $mode eq 'example';
    do_all($ctx)         if $mode eq 'all';
    return 0;
}

# Mode from the command line: all | build | test | clean | example.
sub parse_args {
    my @args = @_;
    my $mode = @args ? shift @args : 'all';
    return $mode if $mode =~ /^(?:all|build|test|clean|example)$/ && !@args;
    print STDERR "usage: builder.pl [all|build|test|clean|example]\n";
    exit 2;
}

# ----------------------------------------------------------------- modes

sub do_clean {
    my ($ctx) = @_;
    remove_venv($ctx);
    print "builder: cleaned\n";
    return 0;
}

sub do_all {
    my ($ctx) = @_;
    find_toolchain($ctx);
    do_build($ctx);
    do_test($ctx);
    #do_example($ctx); # optional
    return 0;
}

sub do_build {
    my ($ctx) = @_;
    create_venv($ctx);
    link_sources($ctx);
    install_qt($ctx);
    verify_imports($ctx);
    print "builder: OK -> $ctx->{venv}\n";
    return 0;
}

sub do_test {
    my ($ctx) = @_;
    chdir "$ctx->{root}/bin"
      or fail("chdir $ctx->{root}/bin: $!");    # like any other test
    return venv_run( $ctx, $ctx->{vpython}, '-m', 'unittest', 'discover', '-s',
        $ctx->{tests}, '-v' );
}

sub do_example {
    my ($ctx) = @_;
    chdir "$ctx->{root}/bin"
      or fail("chdir $ctx->{root}/bin: $!");
    return venv_run( $ctx, $ctx->{vpython}, $ctx->{example} );
}

# ----------------------------------------------------- component specifics

sub build_context {
    my $here = abs_path( dirname(__FILE__) );
    my $root = abs_path("$here/../..");
    return {
        here         => $here,
        root         => $root,
        venv         => "$here/.venv",
        vpython      => "$here/.venv/bin/python",
        src          => "$here/src",
        tests        => "$here/tests",
        example      => "$here/examples/table_view.py",
        requirements => "$here/requirements-qt.txt",
    };
}

# Building a venv needs nothing else; testing and example needs the venv and what it calls.
sub check_prerequisites {
    my ( $ctx, $mode ) = @_;
    if ( $mode ne 'build' ) {
        require_artifact( $ctx->{root}, 'lib/lib_cpp_api.so',
            'perl extender/builder.pl' );
        require_artifact( $ctx->{root}, 'bin/cobol_app',
            'perl cobol/builder.pl' );
    }
    if ( $mode eq 'test' || $mode eq 'example') {
        -x $ctx->{vpython}
          or fail(
'the venv does not exist - run: perl bindings/python/builder.pl build'
          );
        return 1;
    }

    return ensure_writable_dirs( $ctx->{here} );
}

# A Python >= 3.10 that can create venvs (on Debian: python3-venv).
sub find_toolchain {
    my ($ctx)      = @_;
    my @candidates = grep { defined && length } ( $ENV{PYTHON}, 'python3' );
    for my $cmd (@candidates) {
        next unless valid_command($cmd);
        my $path = $cmd =~ m{/} ? $cmd : find_in_path($cmd);
        next unless $path && -x $path;
        my ( $rc, $out ) = capture( $path, '-c',
            'import sys; print("%d.%d.%d" % sys.version_info[:3])' );
        next unless $rc == 0 && $out =~ /^(\d+)\.(\d+)\.\d+/;
        next if $1 < 3 || ( $1 == 3 && $2 < 10 );
        chomp $out;

        my ($venv_rc) = capture( $path, '-c', 'import venv, ensurepip' );
        fail(
            "$path cannot create virtual environments; apt install python3-venv"
        ) if $venv_rc != 0;
        print "builder: using $path (Python $out)\n";
        $ctx->{python} = $path;
        return 1;
    }
    fail(   'Python >= 3.10 not found (tried: '
          . join( ' ', @candidates )
          . '); apt install python3 python3-venv or set PYTHON=/path/to/python3'
    );
}

# The environment of every Python/pip process this builder starts: only the
# venv, no user site, no PYTHONPATH, no .pyc written into the source tree.
sub venv_env {
    my %env = %ENV;
    delete @env{
        qw(PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE VIRTUAL_ENV PIP_USER PIP_TARGET)
    };
    @env{
        qw(PYTHONDONTWRITEBYTECODE PYTHONNOUSERSITE PIP_REQUIRE_VIRTUALENV PIP_DISABLE_PIP_VERSION_CHECK PIP_NO_INPUT)
    } = (1) x 5;
    return %env;
}

sub venv_run {
    my ( $ctx, @cmd ) = @_;
    local %ENV = venv_env();
    return run(@cmd);
}

sub venv_capture {
    my ( $ctx, @cmd ) = @_;
    local %ENV = venv_env();
    return capture(@cmd);
}

# Reuses a working venv; recreates a broken or half-made one.
sub create_venv {
    my ($ctx) = @_;
    if ( -x $ctx->{vpython} ) {
        my ($rc) = venv_capture( $ctx, $ctx->{vpython}, '--version' );
        if ( $rc == 0 ) {
            print "builder: reusing $ctx->{venv}\n";
            return 1;
        }
        print "builder: the existing venv is broken, recreating it\n";
    }
    remove_venv($ctx);
    return venv_run( $ctx, $ctx->{python}, '-m', 'venv', $ctx->{venv} );
}

# A .pth file in the venv's site-packages makes the sources importable
# without installing a copy: edit src/, run again, no rebuild.
sub link_sources {
    my ($ctx) = @_;
    my ( $rc, $out ) =
      venv_capture( $ctx, $ctx->{vpython}, '-c',
        'import sysconfig; print(sysconfig.get_paths()["purelib"])' );
    my ($purelib) = split /\n/, $out;
    $rc == 0 && $purelib && -d $purelib
      or fail("cannot find the venv site-packages: $out");

    my $pth = "$purelib/legacy_ledger.pth";
    open( my $fh, '>', $pth ) or fail("cannot write $pth: $!");
    print {$fh} "$ctx->{src}\n";
    close $fh or fail("cannot write $pth: $!");
    print "builder: $pth -> $ctx->{src}\n";
    return 1;
}

# PySide6 from requirements-qt.txt, wheels only. Offline? LEGACY_NO_QT=1.
sub install_qt {
    my ($ctx) = @_;
    if ( ( $ENV{LEGACY_NO_QT} // '' ) eq '1' ) {
        print
"builder: PySide6 skipped (LEGACY_NO_QT=1): legacy_ledger.qt will not import\n";
        return 1;
    }
    -f $ctx->{requirements} or fail("missing $ctx->{requirements}");
    print
"builder: making sure PySide6 is in the venv (the first time downloads ~85 MB; LEGACY_NO_QT=1 skips)\n";
    return venv_run(
        $ctx,         $ctx->{vpython},
        '-m',         'pip',
        'install',    '--only-binary',
        ':all:',      '--disable-pip-version-check',
        '--no-input', '-r',
        $ctx->{requirements},
    );
}

sub verify_imports {
    my ($ctx) = @_;
    my ( $rc, $out ) = venv_capture( $ctx, $ctx->{vpython}, '-c',
        'import legacy_ledger; print(legacy_ledger.__version__)' );
    $rc == 0 or fail("legacy_ledger cannot be imported in the venv:\n$out");
    chomp $out;
    print "builder: legacy_ledger $out importable\n";

    return 1 if ( $ENV{LEGACY_NO_QT} // '' ) eq '1';
    ( $rc, $out ) = venv_capture( $ctx, $ctx->{vpython}, '-c',
        'import PySide6; print(PySide6.__version__)' );
    $rc == 0 or fail("PySide6 cannot be imported in the venv:\n$out");
    chomp $out;
    print "builder: PySide6 $out importable\n";
    return 1;
}

# Only a directory called .venv inside bindings/, never a symlink.
sub remove_venv {
    my ($ctx) = @_;
    my $venv = $ctx->{venv};
    return 1 unless -e $venv || -l $venv;
    fail("refusing to remove $venv")
      if -l $venv
      || basename($venv) ne '.venv'
      || index( $venv, "$ctx->{root}/bindings/" ) != 0;
    remove_tree( $venv, { error => \my $errors } );
    fail("could not remove $venv") if $errors && @$errors;
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
