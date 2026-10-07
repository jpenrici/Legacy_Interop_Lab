#!/usr/bin/env perl
# legacy/dev/setup.pl

=head1 NAME

setup.pl - check, prepare, build and run the whole legacy project

=head1 SYNOPSIS

  setup.pl [all] [options]        check, build, run (default)
  setup.pl check [options]        verify dependencies only (changes nothing)
  setup.pl prepare [options]      install missing tools (runs prepare_legacy_env.pl)
  setup.pl build [options]        run every component's builder, in dependency order
  setup.pl run [NAME...]          run the executables in legacy/bin
  setup.pl clean                  remove everything the builders produced

  Options:
    --gnucobol-version V   GnuCOBOL to use/install: 3.2 or 3.1.2 (default: first found)
    --cobol-home DIR       use the GnuCOBOL installed in DIR (default: $COBOL_HOME,
                           then /opt/gnucobol-3.2, /opt/gnucobol-3.1.2, then cobc in PATH)
    --system-cobol         use the cobc found in PATH (e.g. the apt package) even when
                           a GnuCOBOL exists in /opt
    --strict               treat every deviation from the project design as a failure
    --cobol-cc CMD         C compiler cobc must call (default: gcc-13 when present)
    --bridge-cc CMD        C compiler for the bridge, GCC >= 14 (default: auto)
    --extender-cxx CMD     C++ compiler for the extender, g++ >= 14 (default: auto)
    --prepare              in "all": install missing tools instead of stopping
    --priv METHOD          how to get root when preparing: auto, sudo, su, print
    --root-owned           GnuCOBOL prefix owned by root (see gnucobol_install.pl)
    --no-check             skip the GnuCOBOL test suite when installing it
    --allow-root           build/run even as root (refused by default)
    --yes, -y              answer "yes" to every question
    --help, -h             this text

=head1 DESCRIPTION

One entry point for the project. This file only reads the command line; the
work lives in modules under C<dev/LegacyDev/>:

  LegacyDev::Components   the manifest: which components exist, what each
                          needs and produces (add a component = add an entry)
  LegacyDev::Check        what is installed, missing or deviating
  LegacyDev::Pipeline     build / run / clean / prepare, driven by the manifest

Each component keeps its own C<builder.pl> and can be built alone; this script
only calls them, through the same contract (C<[all|build|test|clean]>). The
builders never need root, so neither do build, run and clean: they refuse to
run as root unless C<--allow-root> is given, because the files would end up
owned by root. Only C<prepare> can need privileges (apt, /opt); it asks for
them itself, with sudo, su, or by printing the commands.

Everything is derived from the location of this file (C<legacy/dev>), so the
tree can live anywhere.

=head2 Flexible, but it tells you what it thinks

The project is B<designed> for GnuCOBOL 3.1.2 (verified) or 3.2 in
C</opt/gnucobol-V>, built minimal (C<libcob> needs only libgmp and libc), with
GCC 13 compiling the generated C and GCC E<gt>= 14 for the C bridge and the C++
extender. That is the recommendation, not a requirement: whatever is installed
is accepted, namely the C<cobc> from C<--cobol-home>, C<$COBOL_HOME>, /opt, or
finally PATH (for example the apt package, even GnuCOBOL 4.x). When the setup
deviates, the report shows a C<WARN> that says why, using measurements where
possible (for instance how many libraries, and how many MB, the system
C<libcob> would drag into C<lib/>), and a final B<recommendation> block shows
how to get the designed setup. C<--strict> turns those warnings into failures,
for CI.

Hard requirements stay hard because the builds enforce them: GCC E<gt>= 14 and
CMake (3.16 for the bridge, 3.25 for the extender), a working C<cobc> and a C
compiler for COBOL.

=head1 COMMANDS

=over 4

=item B<check>

Read-only. Verifies the platform, Perl core modules, the tools each component
asks for in the manifest, the GnuCOBOL installation, the sources and data
files, that the builders' shared helper block is identical, and what is
already built. Finishes with C<gnucobol_install.pl status>. Each line is
C<OK>, C<WARN> or C<FAIL>; any C<FAIL> makes the exit status 1.

=item B<prepare>

Runs C<prepare_legacy_env.pl> (apt packages and GnuCOBOL in /opt) with the
options you pass. It may need root; see C<--priv>.

=item B<build>

Runs each component's C<builder.pl build> in dependency order (COBOL, C
bridge, C++ extender) with the toolchain found by C<check>.

=item B<run>

Runs the executables of the manifest from C<legacy/bin> with a scrubbed
environment (no LD_LIBRARY_PATH, COBOL_HOME, COB_*, LEGACY_HOME), which proves
the tree is self-contained. Before that it checks with C<ldd> that every
library resolves inside C<legacy/lib>. Exit codes of C<legacy_app>: 0 ok,
1 input file, 2 output file, 3 done with rejected lines, 4 overflow. Naming
executables (C<setup.pl run legacy_app>) runs only those. The test programs
regenerate C<data/store/cobol/cb_data.dat>.

=item B<all>

C<check>, then C<build>, then C<run>. When a dependency is missing it stops
with the fix, or with C<--prepare> installs it and checks again.

=item B<clean>

Calls the C<clean> mode of every builder, dependents first. Data files are
never touched.

=back

=head1 EXIT STATUS

0 success, 1 failure (missing dependency, failed build or run), 2 usage error,
3 a privileged step is pending (commands were printed; run them as root and
run this script again).

=head1 EXAMPLES

  perl dev/setup.pl                          # check + build + run
  perl dev/setup.pl check
  perl dev/setup.pl all --prepare --priv su  # install what is missing first
  perl dev/setup.pl build --cobol-home /opt/gnucobol-3.1.2
  perl dev/setup.pl all --system-cobol       # use the apt GnuCOBOL, with warnings
  perl dev/setup.pl check --system-cobol --strict
  perl dev/setup.pl run legacy_extender_test

=cut

use strict;
use warnings;
use FindBin qw($RealBin);
use lib $RealBin;
use Getopt::Long qw(GetOptionsFromArray);
use Pod::Usage;
use LegacyDev;
use LegacyDev::Check qw(cmd_check set_strict);
use LegacyDev::Pipeline
  qw(cmd_prepare cmd_build cmd_run cmd_clean cmd_all allow_root);

# ------------------------------------------------------------------ main

sub main {
    my ( $command, $opt, $names ) = parse_cli(@_);
    apply_options($opt);
    return dispatch( $command, $opt, $names );
}

# ----------------------------------------------------------------- steps

# Command line -> ( command, options hash, executable names for "run" ).
sub parse_cli {
    my @args = @_;
    my %opt;

    GetOptionsFromArray(
        \@args,               \%opt,
        'gnucobol-version=s', 'cobol-home=s',
        'cobol-cc=s',         'bridge-cc=s',
        'extender-cxx=s',     'system-cobol',
        'strict',             'prepare',
        'priv=s',             'root-owned',
        'allow-root',         'check!',
        'yes|y',              'help|h',
    ) or pod2usage( -exitval => 2, -verbose => 0 );
    pod2usage( -exitval => 0, -verbose => 1 ) if $opt{help};

    my $command = @args ? shift @args : 'all';
    usage_error("unknown command: $command")
      unless $command =~ /^(?:all|check|prepare|build|run|clean)$/;
    usage_error("unexpected arguments: @args") if @args && $command ne 'run';

    $opt{priv} //= 'auto';
    usage_error("invalid --priv: $opt{priv}")
      unless $opt{priv} =~ /^(?:auto|sudo|su|print)$/;
    usage_error('--system-cobol conflicts with --cobol-home')
      if $opt{'system-cobol'} && $opt{'cobol-home'};

    return ( $command, \%opt, \@args );
}

# Hands the options to the modules that care about them.
sub apply_options {
    my ($opt) = @_;
    $LegacyDev::PRIV_REQUEST = $opt->{priv};
    $LegacyDev::ASSUME_YES   = 1 if $opt->{yes};
    set_strict( $opt->{strict} );
    allow_root( $opt->{'allow-root'} );
    return;
}

sub dispatch {
    my ( $command, $opt, $names ) = @_;
    my %handler = (
        all     => sub { cmd_all($opt) },
        check   => sub { cmd_check($opt) },
        prepare => sub { cmd_prepare($opt) },
        build   => sub { cmd_build($opt) },
        run     => sub { cmd_run($names) },
        clean   => sub { cmd_clean() },
    );
    return $handler{$command}->();
}

sub usage_error {
    my ($message) = @_;
    pod2usage( -exitval => 2, -verbose => 0, -message => $message );
}

# ------------------------------------------------------------------ go

exit( main(@ARGV) // 0 ) unless caller;
1;
