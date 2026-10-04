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
    --skip-gnucobol        only prepare the compilers
    --yes, -y              answer "yes" to every question
    --help, -h             this text

=head1 DESCRIPTION

Two toolchains, one per side of the project:

=over 4

=item * B<COBOL side> - GCC 13 (C<gcc-13>) and GnuCOBOL built from source
into C</opt/gnucobol-V>. C<cobc> translates COBOL to C and calls GCC 13.

=item * B<C bridge> - GCC 14 or newer and CMake (the bridge refuses older GCC).

=back

The steps are idempotent: anything already present is left alone. Packages
come from apt (sudo is used only for that); GnuCOBOL is delegated to
C<gnucobol_install.pl>. Nothing is added to PATH or ld.so.conf; the final
message shows the per-shell commands that build the project.

C<uninstall> removes only the GnuCOBOL prefixes created by
C<gnucobol_install.pl>. apt packages are never removed, because other
software may depend on them.

=head1 EXIT STATUS

0 success, 1 failure, 2 usage error.

=cut

use strict;
use warnings;
use FindBin qw($RealBin);
use lib $RealBin;
use Getopt::Long qw(GetOptionsFromArray);
use Pod::Usage;
use Cwd       qw(abs_path);
use LegacyDev qw(
  info warnx fatal step can_run gcc_major os_release apt_ensure pkg_missing
);

# ---------------------------------------------------------------- data

my $COBOL_CC       = 'gcc-13';    # compiler cobc calls
my $BRIDGE_MIN_GCC = 14;          # bridge/CMakeLists.txt requirement

my @COBOL_PKGS =
  qw(gcc-13 build-essential libgmp-dev curl xz-utils gnupg ca-certificates);
my @BRIDGE_PKGS = qw(gcc-14 cmake);

my $INSTALLER = "$RealBin/gnucobol_install.pl";
my $LEGACY    = abs_path("$RealBin/..");

# ---------------------------------------------------------------- main

sub main {
    my @args = @_;
    my %opt  = ( check => 1 );
    my @versions;

    GetOptionsFromArray(
        \@args, \%opt,
        'gnucobol-version=s' => \@versions,
        'check!', 'skip-gnucobol', 'yes|y', 'help|h',
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

    return cmd_status()                       if $cmd eq 'status';
    return cmd_install( \%opt, \@versions )   if $cmd eq 'install';
    return cmd_uninstall( \%opt, \@versions ) if $cmd eq 'uninstall';
}

# ------------------------------------------------------------- helpers

# Runs gnucobol_install.pl as a child; returns its exit status.
sub installer {
    my @args = @_;
    -f $INSTALLER or fatal("missing $INSTALLER");
    return system( $^X, $INSTALLER, @args ) == 0 ? 0 : 1;
}

# First compiler that meets the bridge requirement, or undef.
sub bridge_compiler {
    for my $cc (qw(gcc-15 gcc-14 gcc)) {
        my $v = gcc_major($cc);
        return ( $cc, $v ) if $v && $v >= $BRIDGE_MIN_GCC;
    }
    return;
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

    step( 1, $total, 'Platform' );
    check_platform();

    step( 2, $total, 'Compilers and tools from apt' );
    apt_ensure( @COBOL_PKGS, @BRIDGE_PKGS );

    step( 3, $total, 'Checking compilers' );
    my $major = gcc_major($COBOL_CC) // fatal("$COBOL_CC is not usable");
    fatal("$COBOL_CC reports GCC $major, expected 13") unless $major == 13;
    info("COBOL side : $COBOL_CC (GCC $major)");
    my ( $bcc, $bmajor ) = bridge_compiler();
    $bcc
      or fatal(
        "no GCC >= $BRIDGE_MIN_GCC found for the bridge (apt install gcc-14)");
    info("C bridge   : $bcc (GCC $bmajor)");
    can_run('cmake') or fatal('cmake not found');
    can_run('perl')  or fatal('perl not found');

    if ( $opt->{'skip-gnucobol'} ) {
        info('GnuCOBOL skipped (--skip-gnucobol)');
    }
    else {
        step( 4, $total, 'GnuCOBOL (built from source into /opt)' );
        for my $v (@$versions) {
            my @a = ( 'install', '--version', $v, '--cc', $COBOL_CC );
            push @a, '--no-check' unless $opt->{check};
            push @a, '--yes' if $opt->{yes};
            installer(@a) == 0 or fatal("GnuCOBOL $v installation failed");
        }
    }

    print_next_steps( $versions, $bcc );
    return 0;
}

sub print_next_steps {
    my ( $versions, $bcc ) = @_;
    my $v = $versions->[0];
    print <<"TXT";

[legacy] Environment ready. Build the project (nothing is global; everything per shell):

    cd $LEGACY
    COBOL_HOME=/opt/gnucobol-$v perl cobol/builder.pl
    CC=$bcc perl bridge/builder.pl

[legacy] Switch GnuCOBOL version by changing COBOL_HOME. To compare versions,
[legacy] build with each one and compare the md5 of data/store/cobol/cb_data.dat.
TXT
}

# -------------------------------------------------------------- status

sub cmd_status {
    info('compilers and tools:');
    for my $cc ( $COBOL_CC, qw(gcc-14 gcc) ) {
        my $v = gcc_major($cc);
        info(
            sprintf( '  %-7s %s', $cc, defined $v ? "GCC $v" : 'not found' ) );
    }
    for my $t (qw(cmake sudo)) {
        info( sprintf( '  %-7s %s', $t, can_run($t) ? 'found' : 'not found' ) );
    }
    my @missing =
      can_run('dpkg-query') ? pkg_missing( @COBOL_PKGS, @BRIDGE_PKGS ) : ();
    info( @missing
        ? "  missing apt packages: @missing"
        : '  all required apt packages are installed' );
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
        installer(@a) == 0 or fatal("uninstall of GnuCOBOL $v failed");
    }
    info(
'apt packages (gcc-13, gcc-14, cmake, ...) were left installed on purpose'
    );
    return 0;
}

exit( main(@ARGV) // 0 ) unless caller;
1;
