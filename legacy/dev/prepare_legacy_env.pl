#!/usr/bin/env perl
# legacy/dev/prepare_legacy_env.pl

=head1 NAME

prepare_legacy_env.pl - prepare a Debian 13 machine to build the legacy project

=head1 SYNOPSIS

  prepare_legacy_env.pl [install] [options]   install what is missing (default)
  prepare_legacy_env.pl status                show what is installed
  prepare_legacy_env.pl uninstall [options]   remove the GnuCOBOL prefixes

  Options:
    --gnucobol-version V   3.2 (default) or 3.1.2; may be repeated
    --no-check             skip the GnuCOBOL test suite (faster)
    --priv METHOD          how to get root: auto (default), sudo, su, print
    --root-owned           install GnuCOBOL owned by root (privileged copy at the end)
    --skip-gnucobol        only prepare the compilers
    --yes, -y              answer "yes" to every question
    --help, -h             this text

=head1 DESCRIPTION

Two toolchains, one per side of the project:

=over 4

=item * B<COBOL side> - GCC 13 (C<gcc-13>) and GnuCOBOL built from source
into C</opt/gnucobol-V>. C<cobc> translates COBOL to C and calls GCC 13.

=item * B<C bridge> - GCC 14 or newer and CMake 3.16 or newer (the bridge refuses older GCC).

=item * B<C++ extender> - g++ 14 or newer and CMake 3.25 or newer.

=item * B<Python bindings> - Python 3.10 or newer with the C<venv> module
(Debian: C<python3-venv>). PySide6 itself is not installed here: it is
downloaded into the bindings' own venv by C<bindings/python/builder.pl>.

=back

The steps are idempotent: anything already present is left alone. Packages
come from apt; GnuCOBOL is delegated to C<gnucobol_install.pl>.

Root is needed only for apt and for the /opt prefix. It is obtained with
sudo, with su (root password) or, when neither is possible, by printing the
exact commands for you to run as root (C<--priv auto|sudo|su|print>). By
default the GnuCOBOL prefix is handed over to your user once, so the build
and install run without privileges; see C<gnucobol_install.pl --help>. Nothing is added to PATH or ld.so.conf; the final
message shows the per-shell commands that build the project.

C<uninstall> removes only the GnuCOBOL prefixes created by
C<gnucobol_install.pl>. apt packages are never removed, because other
software may depend on them.

=head1 EXIT STATUS

0 success, 1 failure, 2 usage error, 3 a privileged step is pending (the
commands were printed; run them as root and run this script again).

=cut

use strict;
use warnings;
use FindBin qw($RealBin);
use lib $RealBin;
use Getopt::Long qw(GetOptionsFromArray);
use Pod::Usage;
use Cwd       qw(abs_path);
use LegacyDev qw(
  info warnx fatal step can_run gcc_major capture_status os_release apt_ensure pkg_missing
  priv_describe
);

# ---------------------------------------------------------------- data

my $COBOL_CC       = 'gcc-13';    # compiler cobc calls
my $NATIVE_MIN_GCC = 14;     # bridge/CMakeLists.txt and extender/CMakeLists.txt
my $CMAKE_MIN      = '3.25'; # extender/CMakeLists.txt (the bridge needs 3.16)
my $PYTHON_MIN     = '3.10'; # bindings/python (PySide6 wheels are cp310-abi3)

my @COBOL_PKGS =
  qw(gcc-13 build-essential libgmp-dev curl xz-utils gnupg ca-certificates);
my @NATIVE_PKGS = qw(gcc-14 g++-14 cmake python3 python3-venv)
  ;                          # C bridge, C++ extender, Python bindings

my $INSTALLER = "$RealBin/gnucobol_install.pl";
my $PRIV      = 'auto';
my $LEGACY    = abs_path("$RealBin/..");

# ---------------------------------------------------------------- main

sub main {
    my @args = @_;
    my %opt  = ( check => 1 );
    my @versions;

    GetOptionsFromArray(
        \@args, \%opt,
        'gnucobol-version=s' => \@versions,
        'check!', 'skip-gnucobol', 'yes|y', 'priv=s', 'root-owned', 'help|h',
    ) or pod2usage( -exitval => 2, -verbose => 0 );
    pod2usage( -exitval => 0, -verbose => 1 ) if $opt{help};

    my $cmd = @args ? shift @args : 'install';
    pod2usage(
        -exitval => 2,
        -verbose => 0,
        -message => "unexpected arguments: @args"
    ) if @args;
    pod2usage(
        -exitval => 2,
        -verbose => 0,
        -message => "unknown command: $cmd"
    ) unless $cmd =~ /^(install|status|uninstall)$/;

    @versions              = ('3.2') unless @versions;
    $LegacyDev::ASSUME_YES = 1 if $opt{yes};
    $opt{priv} //= 'auto';
    pod2usage(
        -exitval => 2,
        -verbose => 0,
        -message => "invalid --priv: $opt{priv}"
    ) unless $opt{priv} =~ /^(auto|sudo|su|print)$/;
    $LegacyDev::PRIV_REQUEST = $opt{priv};
    $PRIV                    = $opt{priv};

    return cmd_status()                       if $cmd eq 'status';
    return cmd_install( \%opt, \@versions )   if $cmd eq 'install';
    return cmd_uninstall( \%opt, \@versions ) if $cmd eq 'uninstall';
}

# ------------------------------------------------------------- helpers

# Runs gnucobol_install.pl as a child; returns its exit code (3 = a
# privileged step is pending and its commands were printed).
sub installer {
    my @args = @_;
    -f $INSTALLER or fatal("missing $INSTALLER");
    my $rc = system( $^X, $INSTALLER, @args, '--priv', $PRIV );
    return $rc == -1 ? 1 : ( $rc & 127 ) ? 1 : $rc >> 8;
}

# First of the candidates that is a GCC of at least $NATIVE_MIN_GCC: ($cmd, $major).
sub native_compiler {
    for my $cc (@_) {
        my $v = gcc_major($cc);
        return ( $cc, $v ) if $v && $v >= $NATIVE_MIN_GCC;
    }
    return;
}

# "3.12.3" when python3 is >= $PYTHON_MIN and can create venvs, else undef.
sub python_version {
    my ( $rc, $out ) = capture_status( 'python3', '-c',
        'import sys; print("%d.%d.%d" % sys.version_info[:3])' );
    return unless $rc == 0 && $out =~ /^((\d+)\.(\d+)\.\d+)/;
    my ( $version, $maj, $min ) = ( $1, $2, $3 );
    my ( $nmaj, $nmin ) = split /\./, $PYTHON_MIN;
    return unless $maj > $nmaj || ( $maj == $nmaj && $min >= $nmin );
    my ($venv_rc) = capture_status( 'python3', '-c', 'import venv, ensurepip' );
    return $venv_rc == 0 ? $version : undef;
}

# "3.28.3" >= "3.25" ?
sub cmake_at_least {
    my ($need) = @_;
    my ( $rc, $out ) = capture_status( 'cmake', '--version' );
    return 0 unless $rc == 0 && $out =~ /cmake version (\d+)\.(\d+)/;
    my ( $maj, $min ) = ( $1, $2 );
    my ( $nmaj, $nmin ) = split /\./, $need;
    return ( $maj > $nmaj || ( $maj == $nmaj && $min >= $nmin ) ) ? 1 : 0;
}

sub check_platform {
    my $os = os_release();
    my ( $id, $ver ) = ( $os->{ID} // '?', $os->{VERSION_ID} // '?' );
    $ver =~ s/"//g;
    $id  =~ s/"//g;
    if ( $id eq 'debian' && $ver eq '13' ) {
        info('platform: Debian 13');
    }
    else {
        warnx(
"platform is $id $ver, the target is Debian 13; continuing, packages may differ"
        );
    }
}

# ------------------------------------------------------------- install

sub cmd_install {
    my ( $opt, $versions ) = @_;
    my $total = $opt->{'skip-gnucobol'} ? 3 : 4;

    step( 1, $total, 'Platform and privileges' );
    check_platform();
    info( 'privileges: ' . priv_describe() );

    step( 2, $total, 'Compilers and tools from apt' );
    apt_ensure( @COBOL_PKGS, @NATIVE_PKGS );

    step( 3, $total, 'Checking compilers' );
    my $major = gcc_major($COBOL_CC) // fatal("$COBOL_CC is not usable");
    fatal("$COBOL_CC reports GCC $major, expected 13") unless $major == 13;
    info("COBOL side : $COBOL_CC (GCC $major)");
    my ( $bcc, $bmajor ) = native_compiler(qw(gcc-15 gcc-14 gcc));
    $bcc
      or fatal(
        "no GCC >= $NATIVE_MIN_GCC found for the bridge (apt install gcc-14)");
    info("C bridge   : $bcc (GCC $bmajor)");
    my ( $cxx, $cmajor ) = native_compiler(qw(g++-15 g++-14 g++));
    $cxx
      or fatal(
        "no g++ >= $NATIVE_MIN_GCC found for the extender (apt install g++-14)"
      );
    info("C++ extender: $cxx (GCC $cmajor)");
    can_run('cmake') or fatal('cmake not found');
    cmake_at_least($CMAKE_MIN)
      or fatal(
        "cmake >= $CMAKE_MIN is required by the extender (apt install cmake)");
    my $python = python_version();
    $python
      or fatal(
"Python >= $PYTHON_MIN with the venv module not found (apt install python3 python3-venv)"
      );
    info("Python     : python3 ($python, venv ok)");
    can_run('perl') or fatal('perl not found');

    if ( $opt->{'skip-gnucobol'} ) {
        info('GnuCOBOL skipped (--skip-gnucobol)');
    }
    else {
        step( 4, $total, 'GnuCOBOL (built from source into /opt)' );
        for my $v (@$versions) {
            my @a = ( 'install', '--version', $v, '--cc', $COBOL_CC );
            push @a, '--no-check' unless $opt->{check};
            push @a, '--yes'        if $opt->{yes};
            push @a, '--root-owned' if $opt->{'root-owned'};
            my $rc = installer(@a);
            return 3 if $rc == 3;    # commands printed: run them, then re-run
            fatal("GnuCOBOL $v installation failed") if $rc != 0;
        }
    }

    print_next_steps( $versions, $bcc, $cxx );
    return 0;
}

sub print_next_steps {
    my ( $versions, $bcc, $cxx ) = @_;
    my $v = $versions->[0];
    print <<"TXT";

[legacy] Environment ready. Build the project (nothing is global; everything per shell):

    cd $LEGACY
    COBOL_HOME=/opt/gnucobol-$v perl cobol/builder.pl
    CC=$bcc perl bridge/builder.pl
    CXX=$cxx perl extender/builder.pl
    perl bindings/python/builder.pl          # venv + PySide6 (LEGACY_NO_QT=1 skips the download)

[legacy] or all at once, with the checks:  perl dev/setup.pl

[legacy] Switch GnuCOBOL version by changing COBOL_HOME. To compare versions,
[legacy] build with each one and compare the md5 of data/store/cobol/cb_data.dat.
TXT
}

# -------------------------------------------------------------- status

sub cmd_status {
    info( 'privileges: ' . priv_describe() );
    info('compilers and tools:');
    for my $cc ( $COBOL_CC, qw(gcc-14 g++-14 gcc) ) {
        my $v = gcc_major($cc);
        info(
            sprintf( '  %-7s %s', $cc, defined $v ? "GCC $v" : 'not found' ) );
    }
    for my $t (qw(cmake sudo)) {
        info( sprintf( '  %-7s %s', $t, can_run($t) ? 'found' : 'not found' ) );
    }
    my @missing =
      can_run('dpkg-query') ? pkg_missing( @COBOL_PKGS, @NATIVE_PKGS ) : ();
    info(
        @missing
        ? "  missing apt packages: @missing"
        : '  all required apt packages are installed'
    );
    print "\n";
    installer('status');
    return 0;
}

# ----------------------------------------------------------- uninstall

sub cmd_uninstall {
    my ( $opt, $versions ) = @_;
    for my $v (@$versions) {
        my @a = ( 'uninstall', '--version', $v );
        push @a, '--yes' if $opt->{yes};
        my $rc = installer(@a);
        return 3                                 if $rc == 3;
        fatal("uninstall of GnuCOBOL $v failed") if $rc != 0;
    }
    info(
'apt packages (gcc-13, gcc-14, cmake, ...) were left installed on purpose'
    );
    return 0;
}

exit( main(@ARGV) // 0 ) unless caller;
1;
