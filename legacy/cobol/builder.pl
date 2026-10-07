#!/usr/bin/env perl
# legacy/cobol/builder.pl

=head1 NAME

builder.pl - build (and smoke-test) the COBOL ledger, C<legacy/bin/cobol_app>

=head1 SYNOPSIS

  perl cobol/builder.pl [all|build|test|clean]        (default: all)

  COBOL_HOME=/opt/gnucobol-3.1.2 perl cobol/builder.pl

=head1 DESCRIPTION

Compiles C<cobol/src/ledger.cob> into C<bin/cobol_app> and makes the tree
self-contained: C<libcob> and its dependencies are copied into C<lib/> and the
executable finds them through C<$ORIGIN/../lib>, wherever the tree is moved to.

Recommended toolchain: GnuCOBOL 3.1.2 (verified) or 3.2, built minimal
(C<--without-db --without-xml2 --without-json --without-curses>), so that
C<libcob> needs only libgmp and libc. See C<dev/gnucobol_install.pl>. Any other
installed GnuCOBOL is accepted; C<dev/setup.pl check> explains the trade-offs.

=over 4

=item B<build>  compile, bundle the libraries, verify they resolve inside lib/

=item B<test>   run bin/cobol_app (must be built)

=item B<all>    build, then test

=item B<clean>  remove bin/cobol_app and the libraries this builder bundled

=back

=head1 ENVIRONMENT

  COBC=/path/to/cobc        the compiler to use
  COBOL_HOME=/opt/...       uses $COBOL_HOME/bin/cobc (when COBC is not set)
  COB_CC=gcc-13             the C compiler cobc calls
  LEGACY_ALLOW_ROOT=1       allow running as root (refused by default)

Without COBC and COBOL_HOME, C<cobc> is taken from PATH. Compiler flags and
library paths inherited from the caller are discarded.

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
    unlink $ctx->{exe};
    remove_bundled($ctx);
    print "builder: cleaned\n";
    return 0;
}

sub do_build {
    my ($ctx) = @_;
    remove_bundled($ctx);    # first, so no stale library can be picked up
    compile($ctx);
    bundle_libraries($ctx);
    verify_relocatable($ctx);
    print "builder: OK -> $ctx->{exe}\n";
    return 0;
}

sub do_test {
    my ($ctx) = @_;
    return run_test_binary( $ctx->{root}, 'cobol_app' );
}

# ----------------------------------------------------- component specifics

# Libraries that belong to the C library: never copied into lib/.
my %CORE_LIBS = map { $_ => 1 }
  qw(linux-vdso libc libm libdl libpthread librt libgcc_s ld-linux-x86-64 ld-linux-aarch64);

sub build_context {
    my $root = abs_path( dirname(__FILE__) . '/..' );
    return {
        root     => $root,
        src      => "$root/cobol/src/ledger.cob",
        bin      => "$root/bin",
        lib      => "$root/lib",
        exe      => "$root/bin/cobol_app",
        manifest =>
          "$root/lib/.cobol-bundled",    # what this builder copied into lib/
    };
}

sub check_prerequisites {
    my ( $ctx, $mode ) = @_;
    return 1 if $mode eq 'test';
    -f $ctx->{src} or fail("source not found: $ctx->{src}");
    return ensure_writable_dirs( $ctx->{bin}, $ctx->{lib} );
}

# cobc from COBC, else $COBOL_HOME/bin/cobc, else PATH.
sub locate_cobc {
    my $cobc = $ENV{COBC};
    $cobc = "$ENV{COBOL_HOME}/bin/cobc" if !$cobc && $ENV{COBOL_HOME};
    $cobc //= find_in_path('cobc');
    $cobc && valid_command($cobc)
      or fail('cobc not found (set COBC or COBOL_HOME)');
    -x $cobc or fail("cobc is not executable: $cobc");
    return $cobc;
}

sub find_toolchain {
    my ($ctx) = @_;
    my $cobc = locate_cobc();
    fail("COB_CC is not a plain command name: $ENV{COB_CC}")
      if defined $ENV{COB_CC} && !valid_command( $ENV{COB_CC} );

    my ( $rc, $out ) = capture( $cobc, '--version' );
    my ($version) = $out =~ /\(GnuCOBOL\)\s+(\d+\.\d+)/;
    fail('cannot read the cobc version') unless $rc == 0 && $version;
    print "builder: cobc $version at $cobc\n";
    print "builder: WARNING only GnuCOBOL 3.1 and 3.2 are expected to work\n"
      unless $version =~ /^3\.[12]$/;
    print
      "builder: NOTE 3.2 is not yet verified with this project; compare the\n",
"builder:      md5 of data/store/cobol/cb_data.dat against a 3.1.2 build\n"
      if $version eq '3.2';

    my ( $irc, $info ) = capture( $cobc, '--info' );
    my ($default_cc) = $info =~ /COB_CC\s*:\s*(\S+)/;
    print 'builder: C compiler = ', ( $ENV{COB_CC} // $default_cc // '?' ),
      "\n";

    $ctx->{cobc} = $cobc;
    $ctx->{cobdir} =
      ( $info =~ /COB_LIBS\s*:.*?-L(\S+)/ )[0];    # where its libcob lives
    return 1;
}

# -Q passes the linker option: the executable finds ../lib at run time. It is
# DT_RPATH (not RUNPATH) on purpose: it also reaches libcob's own dependency
# (libgmp); RUNPATH would not.
sub compile {
    my ($ctx) = @_;
    return run(
        $ctx->{cobc}, '-x',
        '-fixed',     '-std=default',
        '-Wall',      '-O2',
        '-Q',         '-Wl,--disable-new-dtags,-rpath,$ORIGIN/../lib',
        '-o',         $ctx->{exe},
        $ctx->{src},
    );
}

# ldd output for $file; $libpath says where to look first (the libcob cobc linked).
sub ldd_output {
    my ( $file, $libpath ) = @_;
    local $ENV{LD_LIBRARY_PATH} = $libpath // '';
    my ( $rc, $out ) = capture( 'ldd', $file );
    $rc == 0 or fail("ldd failed for $file: $out");
    return $out;
}

# Copies every non-system dependency of the executable into lib/.
sub bundle_libraries {
    my ($ctx) = @_;
    my @bundled;
    for my $line ( split /\n/, ldd_output( $ctx->{exe}, $ctx->{cobdir} ) ) {
        next unless $line =~ m{^\s*(\S+)\s+=>\s+(/\S+)};
        my ( $name, $path ) = ( $1, $2 );
        ( my $base = $name ) =~ s/\.so.*$//;
        next if $CORE_LIBS{$base};

        my $real = abs_path($path) // $path;
        my $dest = "$ctx->{lib}/$name";
        if ( $real ne ( -e $dest ? abs_path($dest) : '' ) )
        {    # not already the copy in lib/
            unlink $dest;
            copy( $real, $dest ) or fail("copy $path: $!");
        }
        push @bundled, $name;
        print "builder: bundled $name\n";
    }
    open( my $fh, '>', $ctx->{manifest} )
      or fail("cannot write $ctx->{manifest}: $!");
    print {$fh} map { "$_\n" } @bundled;
    close $fh;
    return 1;
}

# With a clean environment every library must resolve inside lib/.
sub verify_relocatable {
    my ($ctx) = @_;
    my %seen;
    for my $line ( split /\n/, ldd_output( $ctx->{exe}, '' ) ) {
        next unless $line =~ m{^\s*(\S+)\s+=>\s+(\S+)};
        my ( $name, $path ) = ( $1, $2 );
        ( my $base = $name ) =~ s/\.so.*$//;
        next                    if $CORE_LIBS{$base};
        fail("$name not found") if $path eq 'not';
        my $real = abs_path($path) // $path;
        fail("$name resolves outside lib/: $real")
          unless index( $real, "$ctx->{lib}/" ) == 0;
        $seen{$base} = 1;
    }
    for my $need (qw(libcob libgmp)) {
        fail("$need not resolved") unless $seen{$need};
    }
    return 1;
}

# Removes exactly what a previous build copied into lib/ (and the libcob/libgmp
# of trees built before the manifest existed). lib_c_api.so is the bridge's.
sub remove_bundled {
    my ($ctx) = @_;
    my @old;
    if ( open( my $fh, '<', $ctx->{manifest} ) ) {
        chomp( @old = <$fh> );
        close $fh;
    }
    push @old,
      map { basename($_) }
      glob("$ctx->{lib}/libcob.so* $ctx->{lib}/libgmp.so*");
    my %seen;
    for my $name ( grep { length && !$seen{$_}++ } @old ) {
        next if $name =~ m{/} || $name eq 'lib_c_api.so';
        unlink "$ctx->{lib}/$name";
    }
    unlink $ctx->{manifest};
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
