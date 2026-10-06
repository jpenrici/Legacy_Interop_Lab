#!/usr/bin/env perl

=head1 NAME

setup.pl - check, prepare, build and run the whole legacy project

=head1 SYNOPSIS

  setup.pl [all] [options]        check, build, run (default)
  setup.pl check [options]        verify dependencies only (changes nothing)
  setup.pl prepare [options]      install missing tools (runs prepare_legacy_env.pl)
  setup.pl build [options]        run cobol/builder.pl, then bridge/builder.pl
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
    --prepare              in "all": install missing tools instead of stopping
    --priv METHOD          how to get root when preparing: auto, sudo, su, print
    --root-owned           GnuCOBOL prefix owned by root (see gnucobol_install.pl)
    --no-check             skip the GnuCOBOL test suite when installing it
    --yes, -y              answer "yes" to every question
    --help, -h             this text

=head1 DESCRIPTION

One entry point for the sibling scripts. Everything is derived from the
location of this file (C<legacy/dev>), so the tree can live anywhere.

=head2 Flexible, but it tells you what it thinks

The project is B<designed> for GnuCOBOL 3.1.2 (verified) or 3.2 in
C</opt/gnucobol-V>, built minimal (C<libcob> needs only libgmp and libc), with
GCC 13 compiling the generated C and GCC E<gt>= 14 for the bridge. That is the
recommendation, not a requirement: whatever is installed is accepted, namely
the C<cobc> from C<--cobol-home>, C<$COBOL_HOME>, /opt, or finally PATH (for
example the apt package, even GnuCOBOL 4.x). When the setup deviates, the
report shows a C<WARN> that says why, using measurements where possible (for
instance how many libraries, and how many MB, the system C<libcob> would drag
into C<lib/>), and a final B<recommendation> block shows how to get the ideal
setup. C<--strict> turns those warnings into failures, for CI.

Hard requirements stay hard because the build enforces them: GCC E<gt>= 14 and
CMake E<gt>= 3.16 for the bridge, a working C<cobc> and C compiler for COBOL.

=over 4

=item B<check>

Read-only. Verifies the platform, Perl core modules, build tools (GCC 13 for
the COBOL side, GCC E<gt>= 14 and CMake E<gt>= 3.16 for the bridge), the GnuCOBOL
installation, the project sources and the data files, and reports what is
already built. Finishes by running C<gnucobol_install.pl status>. Each line is
C<OK>, C<WARN> or C<FAIL>; any C<FAIL> makes the exit status 1. Deviations from the
project design are C<WARN> (C<FAIL> with C<--strict>).

=item B<prepare>

Runs C<prepare_legacy_env.pl> (apt packages and GnuCOBOL in /opt) with the
options you pass. It may need root; see C<--priv>.

=item B<build>

Runs C<cobol/builder.pl> (COBOL to C<bin/cobol_app>, libcob and libgmp copied
to C<lib/>) and then C<bridge/builder.pl build> (C<lib/lib_c_api.so> and
C<bin/c_bridge_test>) with the toolchain found by C<check>.

=item B<run>

Runs C<bin/cobol_app> and C<bin/c_bridge_test> with C<legacy/bin> as the working
directory and a scrubbed environment (no LD_LIBRARY_PATH, COBOL_HOME, COB_*,
LEGACY_HOME), which proves the tree is self-contained. Before that it checks
with C<ldd> that every library resolves inside C<legacy/lib>. Exit codes of
C<cobol_app>: 0 ok, 1 input file, 2 output file, 3 done with rejected lines,
4 overflow. Naming executables (C<setup.pl run cobol_app>) runs only those.
Note that C<c_bridge_test> regenerates C<data/store/cobol/cb_data.dat>.

=item B<all>

C<check>, then C<build>, then C<run>. When a dependency is missing it stops
with the fix, or with C<--prepare> installs it and checks again.

=item B<clean>

Calls the C<clean> command of both builders. Data files are never touched.

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
  perl dev/setup.pl run cobol_app

=cut

use strict;
use warnings;
use FindBin qw($RealBin);
use lib $RealBin;
use Getopt::Long qw(GetOptionsFromArray);
use Pod::Usage;
use Cwd        qw(abs_path);
use File::Path qw(make_path);
use LegacyDev  qw(
  info warnx fatal step can_run gcc_major capture_status os_release
  priv_describe priv_method
);

# ---------------------------------------------------------------- data

my $LEGACY = abs_path("$RealBin/..");
my %P      = (
    prepare  => "$RealBin/prepare_legacy_env.pl",
    install  => "$RealBin/gnucobol_install.pl",
    cobol_b  => "$LEGACY/cobol/builder.pl",
    bridge_b => "$LEGACY/bridge/builder.pl",
);

# Files the project cannot build without.
my @REQUIRED_FILES = qw(
  cobol/src/ledger.cob cobol/builder.pl
  bridge/builder.pl bridge/CMakeLists.txt bridge/include/api.h
  bridge/src/api.c bridge/tests/main.c
  data/input/cobol/cb_data.csv
);

# Directories the executables expect (created when missing).
my @DATA_DIRS = qw(bin lib data/input/cobol data/store/cobol data/backup);

# Executables run by "run", in order, with the exit codes they may return.
my @EXECUTABLES = (
    {
        name => 'cobol_app',
        ok   => [0],
        warn => { 3 => 'some input lines were rejected' }
    },
    { name => 'c_bridge_test', ok => [0], warn => {} },
);
my %EXIT_MEANING = (
    1 => 'cannot open the input CSV',
    2 => 'cannot write the output .dat',
    3 => 'finished, some input lines were rejected',
    4 => 'amount overflow, run aborted',
);

my %SUPPORTED_COBOL = ( '3.1' => 1, '3.2' => 1 );

# Shared libraries that come with the C library: never bundled into lib/
# (same list as cobol/builder.pl).
my %CORE_LIBS = map { $_ => 1 }
  qw(linux-vdso libc libm libdl libpthread librt libgcc_s ld-linux-x86-64 ld-linux-aarch64);

my $STRICT = 0;    # --strict
my @DEVIATIONS;    # what differs from the project design (this run)
my $BRIDGE_MIN_GCC = 14;
my $CMAKE_MIN      = '3.16';
my @PERL_MODULES =
  qw(Digest::SHA File::Temp File::Find File::Path Getopt::Long Pod::Usage POSIX);

# Environment variables that could leak into the executables.
my @SCRUB_ENV =
  qw(LD_LIBRARY_PATH LD_PRELOAD COBOL_HOME LEGACY_HOME COB_CC COB_CFLAGS COB_LDFLAGS);

# ---------------------------------------------------------------- main

sub main {
    my @args = @_;
    my %opt;

    GetOptionsFromArray(
        \@args,               \%opt,
        'gnucobol-version=s', 'cobol-home=s',
        'cobol-cc=s',         'bridge-cc=s',
        'system-cobol',       'strict',
        'prepare',            'priv=s',
        'root-owned',         'check!',
        'yes|y',              'help|h',
    ) or pod2usage( -exitval => 2, -verbose => 0 );
    pod2usage( -exitval => 0, -verbose => 1 ) if $opt{help};

    my $cmd = @args ? shift @args : 'all';
    pod2usage(
        -exitval => 2,
        -verbose => 0,
        -message => "unknown command: $cmd"
    ) unless $cmd =~ /^(all|check|prepare|build|run|clean)$/;
    pod2usage(
        -exitval => 2,
        -verbose => 0,
        -message => "unexpected arguments: @args"
    ) if @args && $cmd ne 'run';

    $opt{priv} //= 'auto';
    pod2usage(
        -exitval => 2,
        -verbose => 0,
        -message => "invalid --priv: $opt{priv}"
    ) unless $opt{priv} =~ /^(auto|sudo|su|print)$/;
    $LegacyDev::PRIV_REQUEST = $opt{priv};
    $LegacyDev::ASSUME_YES   = 1 if $opt{yes};
    $STRICT                  = $opt{strict} ? 1 : 0;
    pod2usage(
        -exitval => 2,
        -verbose => 0,
        -message => '--system-cobol conflicts with --cobol-home'
    ) if $opt{'system-cobol'} && $opt{'cobol-home'};

    return cmd_check( \%opt )        if $cmd eq 'check';
    return cmd_prepare( \%opt )      if $cmd eq 'prepare';
    return cmd_clean()               if $cmd eq 'clean';
    return cmd_build( \%opt, undef ) if $cmd eq 'build';
    return cmd_run( \@args )         if $cmd eq 'run';
    return cmd_all( \%opt );
}

# ------------------------------------------------------------ reporting

my %tally;

# One entry of the dependency report: level is ok | warn | fail.
# $hint may be a string or an array ref (one "->" line each).
sub report {
    my ( $level, $what, $detail, $hint ) = @_;
    $tally{$level}++;
    my %tag = ( ok => ' OK ', warn => 'WARN', fail => 'FAIL' );
    printf "[%s] %-20s %s\n", $tag{$level}, $what, $detail // '';
    if ( $hint && $level ne 'ok' ) {
        print "       -> $_\n" for ref $hint ? @$hint : $hint;
    }
}

# A deviation from the project design: WARN, or FAIL under --strict.
sub deviation {
    my ( $what, $detail, $hint ) = @_;
    push @DEVIATIONS, $what;
    my @h = ref $hint ? @$hint : ( $hint // () );
    push @h, 'treated as a failure because of --strict' if $STRICT;
    report( $STRICT ? 'fail' : 'warn', $what, $detail, \@h );
}

# ------------------------------------------------------------ discovery

# Full version token as printed by cobc ("3.1.2.0", "4.0-early-dev.0").
sub cobc_version {
    my ($cobc) = @_;
    my ( $rc, $out ) = capture_status( $cobc, '--version' );
    return ( $rc == 0 && $out =~ /\(GnuCOBOL\)\s+(\d\S*)/ ) ? $1 : undef;
}

sub is_system_home {
    my ($home) = @_;
    return ( !defined($home) || $home =~ m{^/usr(?:/local)?/?$} )
      ? 1
      : 0;    # explicit boolean: a bare m{} in list context returns captures
}

# Finds the cobc to use. Any installed GnuCOBOL is accepted; the order only
# reflects the project's preference:
#   --cobol-home / $COBOL_HOME   explicit, no fallback
#   --system-cobol               cobc from PATH, no fallback
#   /opt/gnucobol-3.2, -3.1.2    (or only --gnucobol-version)
#   cobc from PATH
# Returns { home, cobc, version, how, system, ignored } or (undef, $error).
sub find_cobol {
    my ($opt) = @_;
    my $want = $opt->{'gnucobol-version'};

    my ( $dir, $how );
    if ( $opt->{'cobol-home'} ) {
        ( $dir, $how ) = ( $opt->{'cobol-home'}, '--cobol-home' );
    }
    elsif ( !$opt->{'system-cobol'} && $ENV{COBOL_HOME} ) {
        ( $dir, $how ) = ( $ENV{COBOL_HOME}, '$COBOL_HOME' );
    }
    if ($dir) {
        my $cobc = "$dir/bin/cobc";
        return ( undef, "$how=$dir has no executable bin/cobc" )
          unless -x $cobc;
        my $v = cobc_version($cobc)
          or return ( undef, "$cobc does not report a GnuCOBOL version" );
        my $home = abs_path($dir);
        return {
            home    => $home,
            cobc    => $cobc,
            version => $v,
            how     => $how,
            system  => is_system_home($home)
        };
    }

    my $path_cobc = can_run('cobc');
    my $found;

    if ( $opt->{'system-cobol'} ) {
        return ( undef, 'no cobc in PATH' ) unless $path_cobc;
        my $v = cobc_version($path_cobc)
          or return ( undef, "$path_cobc does not report a GnuCOBOL version" );
        return ( undef, "cobc in PATH is $v, not $want" )
          if $want && index( $v, $want ) != 0;
        return {
            home    => undef,
            cobc    => $path_cobc,
            version => $v,
            how     => '--system-cobol',
            system  => 1
        };
    }

    for my $ver ( $want ? ($want) : qw(3.2 3.1.2) ) {
        my $cobc = "/opt/gnucobol-$ver/bin/cobc";
        next unless -x $cobc;
        my $v = cobc_version($cobc) or next;
        $found = {
            home    => "/opt/gnucobol-$ver",
            cobc    => $cobc,
            version => $v,
            how     => '/opt',
            system  => 0
        };
        last;
    }
    if ($found) {    # remember the system cobc we are NOT using
        if ($path_cobc) {
            my $sv = cobc_version($path_cobc);
            $found->{ignored} = { cobc => $path_cobc, version => $sv } if $sv;
        }
        return $found;
    }

    if ($path_cobc) {
        my $v = cobc_version($path_cobc);
        if ( $v && ( !$want || index( $v, $want ) == 0 ) ) {
            return {
                home    => undef,
                cobc    => $path_cobc,
                version => $v,
                how     => 'PATH',
                system  => 1
            };
        }
    }
    return ( undef,
        $want
        ? "GnuCOBOL $want not found in /opt or PATH"
        : 'no GnuCOBOL found in /opt or PATH' );
}

# What the system libcob would drag into lib/: dependencies of libcob other
# than the C library, measured with ldd. Returns an array ref or undef.
sub libcob_deps {
    my ($cobc) = @_;
    my ( $rc, $info ) = capture_status( $cobc, '--info' );
    return if $rc != 0;

    # Where does "-lcob" resolve? An explicit -L wins; otherwise the linker's
    # default directories (cobc 4.x prints no -L for a system install).
    my @dirs;
    push @dirs, $1 if $info =~ /^COB_LIBS\s*:.*?-L(\S+)/m;
    my ( $mrc, $mach ) = capture_status( 'gcc', '-dumpmachine' );
    if ( $mrc == 0 && $mach =~ /(\S+)/ ) {
        push @dirs, "/usr/lib/$1", "/lib/$1";
    }
    push @dirs, qw(/usr/lib64 /usr/lib /usr/local/lib);
    my ( $libdir, $lib );
    for my $d (@dirs) {
        ($lib) = grep { -e $_ } glob("$d/libcob.so $d/libcob.so.*");
        if ($lib) { $libdir = $d; last }
    }
    return unless $lib;
    local $ENV{LD_LIBRARY_PATH} = $libdir;
    my ( $lrc, $out ) = capture_status( 'ldd', $lib );
    return if $lrc != 0;
    my @deps;
    for my $line ( split /\n/, $out ) {
        next unless $line =~ m{^\s*(\S+)\s+=>\s+(/\S+)};
        my ( $name, $path ) = ( $1, $2 );
        ( my $base = $name ) =~ s/\.so.*$//;
        next if $CORE_LIBS{$base} || $base eq 'libcob';
        my $real = abs_path($path) // $path;
        push @deps, { base => $base, name => $name, size => ( -s $real ) // 0 };
    }
    return \@deps;
}

# First GCC >= 14 among the candidates, as (command, major); empty if none.
sub find_bridge_cc {
    my ($opt) = @_;
    my @cand =
      $opt->{'bridge-cc'} ? ( $opt->{'bridge-cc'} ) : qw(gcc-15 gcc-14 gcc);
    for my $cc (@cand) {
        my $v = gcc_major($cc);
        return ( $cc, $v ) if $v && $v >= $BRIDGE_MIN_GCC;
    }
    return;
}

sub cmake_version {
    my ( $rc, $out ) = capture_status( 'cmake', '--version' );
    return ( $rc == 0 && $out =~ /cmake version (\d+\.\d+(?:\.\d+)?)/ )
      ? $1
      : undef;
}

sub version_ge {
    my ( $a, $b ) = @_;
    my @a = split /\./, $a;
    my @b = split /\./, $b;
    for my $i ( 0 .. 2 ) {
        my ( $x, $y ) = ( $a[$i] // 0, $b[$i] // 0 );
        return 1 if $x > $y;
        return 0 if $x < $y;
    }
    return 1;
}

# ---------------------------------------------------------------- check

# Runs every check. Returns a context hash: fails, cobol, cobol_cc, bridge_cc.
sub run_checks {
    my ($opt) = @_;
    %tally = ();
    my %ctx = ( root => $LEGACY );

    info("project root: $LEGACY");
    print "\n-- platform\n";
    my $os = os_release();
    my ( $id, $ver ) =
      map { my $v = $_ // '?'; $v =~ s/"//g; $v } @{$os}{qw(ID VERSION_ID)};
    if ( $id eq 'debian' && $ver eq '13' ) {
        report( ok => 'platform', "Debian $ver" );
    }
    else {
        report(
            warn => 'platform',
            "$id $ver", 'the target is Debian 13; other systems may work'
        );
    }
    report( ok => 'perl', sprintf( '%vd', $^V ) );
    my @missing_mod = grep { !eval "require $_; 1" } @PERL_MODULES;
    if (@missing_mod) {
        report(
            fail => 'perl modules',
            "missing: @missing_mod", 'apt install perl-modules (core modules)'
        );
    }
    else { report( ok => 'perl modules', 'all core modules present' ) }
    if ( priv_method() eq 'print' ) {
        report(
            warn => 'privileges',
            'no automatic root method',
'only "prepare" needs root; it will print the commands (or use --priv su|sudo)'
        );
    }
    else { report( ok => 'privileges', priv_describe() ) }

    print "\n-- COBOL side\n";
    my ( $cobol, $err ) = find_cobol($opt);
    if ( !$cobol ) {
        report(
            fail => 'GnuCOBOL',
            $err,
            [
"perl $RealBin/setup.pl prepare   (installs the recommended one in /opt)",
                'or point to one: --cobol-home DIR / --system-cobol'
            ]
        );
    }
    else {
        $ctx{cobol} = $cobol;
        my $where   = $cobol->{home} // $cobol->{cobc};
        my $v       = $cobol->{version};
        my ($short) = $v =~ /^(\d+\.\d+)/;
        $short //= $v;
        my $line = "cobc $v at $where [$cobol->{how}]";

        if ( $SUPPORTED_COBOL{$short} ) {
            my $note =
              $short eq '3.2' ? ' (not yet verified with this project)' : '';
            report( ok => 'GnuCOBOL', $line . $note );
        }
        elsif ( $short =~ /^4\./ ) {
            deviation(
                'GnuCOBOL version',
                $line,
                [
'the 4.x line is under development (apt "gnucobol4" is a 2020 early snapshot), not a stable release',
'it may compile this project, but file I/O and other behavior may differ from 3.x',
'the project is verified with 3.1.2: build with both and compare data/store/cobol/cb_data.dat',
                ]
            );
        }
        else {
            deviation(
                'GnuCOBOL version',
                $line,
                [
'only 3.1.2 is verified with this project (3.2 is expected to work)',
                ]
            );
        }

        if ( $cobol->{system} ) {
            deviation(
                'cobc origin',
                'system installation (distribution package)',
                [
'its libcob is the distribution build, not the minimal one the project is designed around',
                ]
            );
        }
        if ( my $ig = $cobol->{ignored} ) {
            info(
"note: another cobc ($ig->{version}) exists in PATH ($ig->{cobc}); not used (use --system-cobol)"
            );
        }

        # Measured, not assumed: what would be copied into lib/ ?
        if ( my $deps = libcob_deps( $cobol->{cobc} ) ) {
            my @extra = grep { $_->{base} ne 'libgmp' } @$deps;
            if (@extra) {
                my $mb = 0;
                $mb += $_->{size} for @extra;
                $mb = $mb / 1048576;
                my @names = map { $_->{base} } @extra;
                my $shown = join( ', ',
                    @names > 8 ? ( @names[ 0 .. 7 ], '...' ) : @names );
                deviation(
                    'libcob dependencies',
                    sprintf(
                        '%d extra librar%s (%.1f MB): %s',
                        scalar(@extra), @extra == 1 ? 'y' : 'ies',
                        $mb,            $shown
                    ),
                    [
'cobol/builder.pl will copy all of them into lib/, making the tree bigger and less portable',
'some libraries read system data at run time (e.g. ncurses/terminfo) and may not relocate cleanly',
'a minimal libcob (--without-db --without-xml2 --without-json --without-curses) needs only libgmp',
                    ]
                );
            }
            else {
                report(
                    ok => 'libcob dependencies',
                    'minimal: libgmp + libc only'
                );
            }
        }
        else {
            report(
                warn => 'libcob dependencies',
                'could not locate libcob to assess it',
                'cobol/builder.pl will still check what it bundles'
            );
        }

        my ( $rc, $info ) = capture_status( $cobol->{cobc}, '--info' );
        my ($default_cc) = $info =~ /^COB_CC\s*:\s*(\S+)/m;
        my $cc = $opt->{'cobol-cc'}
          // ( gcc_major('gcc-13') ? 'gcc-13' : $default_cc );
        $ctx{cobol_cc} = $opt->{'cobol-cc'}
          // ( gcc_major('gcc-13') ? 'gcc-13' : undef );
        my $major = $cc ? gcc_major($cc) : undef;
        if ( !$major ) {
            report(
                fail => 'COBOL compiler',
                ( $cc // '?' ) . ' is not usable',
                'apt install gcc-13  (or: --cobol-cc CMD)'
            );
        }
        elsif ( $major != 13 ) {
            deviation(
                'COBOL compiler',
                "$cc is GCC $major",
'the project targets GCC 13 for the generated C (apt install gcc-13)'
            );
        }
        else { report( ok => 'COBOL compiler', "$cc (GCC $major)" ) }
    }

    print "\n-- C bridge\n";
    my ( $bcc, $bmajor ) = find_bridge_cc($opt);
    if ($bcc) {
        $ctx{bridge_cc} = $bcc;
        report( ok => 'bridge compiler', "$bcc (GCC $bmajor)" );
    }
    else {
        report(
            fail => 'bridge compiler',
            "no GCC >= $BRIDGE_MIN_GCC found",
            'apt install gcc-14  (or: --bridge-cc CMD)'
        );
    }
    if ( can_run('cmake') ) {
        my $v = cmake_version();
        if ( $v && version_ge( $v, $CMAKE_MIN ) ) {
            report( ok => 'cmake', $v );
        }
        else {
            report(
                fail => 'cmake',
                ( $v // 'unknown version' ) . " (need >= $CMAKE_MIN)",
                'apt install cmake'
            );
        }
    }
    else { report( fail => 'cmake', 'not found', 'apt install cmake' ) }
    for my $tool (qw(make ldd)) {
        can_run($tool)
          ? report( ok => $tool, can_run($tool) )
          : report( fail => $tool, 'not found', 'apt install build-essential' );
    }

    print "\n-- tools used only to install GnuCOBOL\n";
    for my $tool (qw(curl gpg tar xz)) {
        can_run($tool)
          ? report( ok => $tool, can_run($tool) )
          : report( warn => $tool, 'not found', 'needed only by "prepare"' );
    }

    print "\n-- project files\n";
    my @absent = grep { !-f "$LEGACY/$_" } @REQUIRED_FILES;
    if (@absent) {
        report(
            fail => 'sources and data',
            'missing: ' . join( ', ', @absent )
        );
    }
    else {
        report(
            ok => 'sources and data',
            scalar(@REQUIRED_FILES) . ' required files present'
        );
    }
    my @nodir = grep { !-d "$LEGACY/$_" } @DATA_DIRS;
    @nodir
      ? report(
        warn => 'directories',
        "missing (created on build/run): @nodir"
      )
      : report( ok => 'directories', 'bin lib data/* present' );
    for my $d (qw(bin lib data/store/cobol)) {
        my $path = "$LEGACY/$d";
        report(
            fail => "$d writable",
            'not writable by this user', 'fix the ownership of the tree'
        ) if -d $path && !-w $path;
    }

    print "\n-- build state\n";
    my @built = (
        [ 'bin/cobol_app',   'COBOL executable' ],
        [ 'bin/c_bridge_test',   'bridge test program' ],
        [ 'lib/lib_c_api.so', 'bridge library' ],
    );
    for my $b (@built) {
        -x "$LEGACY/$b->[0]"
          ? report( ok => $b->[1], $b->[0] )
          : report(
            warn => $b->[1],
            "$b->[0] not built yet",
            'setup.pl build'
          );
    }
    my @libs = map { glob("$LEGACY/lib/$_") } qw(libcob.so.* libgmp.so.*);
    @libs
      ? report( ok => 'bundled libs', join( ', ', map { s{.*/}{}r } @libs ) )
      : report(
        warn => 'bundled libs',
        'libcob/libgmp not in lib/ yet', 'setup.pl build'
      );

    print_recommendation() if @DEVIATIONS;

    $ctx{fails} = $tally{fail} // 0;
    printf "\n[legacy] %d ok, %d warning(s), %d failure(s)\n", $tally{ok} // 0,
      $tally{warn} // 0, $ctx{fails};
    return \%ctx;
}

# Shown whenever the setup deviates from the project design.
sub print_recommendation {
    my %seen;
    my @what = grep { !$seen{$_}++ } @DEVIATIONS;
    print "\n-- recommendation\n";
    print <<"TXT";
Your setup is accepted, but it differs from the project design in: @{[ join ', ', @what ]}.
Designed setup:
  * GnuCOBOL 3.1.2 (verified) or 3.2, minimal build, in /opt/gnucobol-V
  * GCC 13 compiling the generated C; GCC >= 14 for the C bridge
To get it (root is needed only for apt and /opt; see --priv):
  perl $RealBin/setup.pl prepare --gnucobol-version 3.1.2
Then compare both builds if you want proof the output is the same:
  md5sum data/store/cobol/cb_data.dat   (after building with each cobc)
TXT
}

sub cmd_check {
    my ($opt) = @_;
    my $ctx = run_checks($opt);
    print "\n-- GnuCOBOL installs (gnucobol_install.pl status)\n";
    child_perl( $P{install}, {}, 'status' ) if -f $P{install};
    return $ctx->{fails} ? 1 : 0;
}

# ------------------------------------------------------------ children

# Runs a perl script with extra environment; returns its exit code.
sub child_perl {
    my ( $script, $env, @args ) = @_;
    -f $script or fatal("missing script: $script");
    local @ENV{ keys %$env } = values %$env if $env && %$env;
    my $rc = system( $^X, $script, @args );
    return $rc == -1 ? 1 : ( $rc & 127 ) ? 1 : $rc >> 8;
}

# -------------------------------------------------------------- prepare

sub cmd_prepare {
    my ($opt) = @_;
    my @a;
    push @a, '--gnucobol-version', $opt->{'gnucobol-version'}
      if $opt->{'gnucobol-version'};
    push @a, '--priv', $opt->{priv};
    push @a, '--root-owned' if $opt->{'root-owned'};
    push @a, '--no-check'   if defined $opt->{check} && !$opt->{check};
    push @a, '--yes'        if $opt->{yes};
    my $rc = child_perl( $P{prepare}, {}, 'install', @a );
    return $rc == 3 ? 3 : $rc ? 1 : 0;
}

# ---------------------------------------------------------------- build

sub cmd_build {
    my ( $opt, $ctx ) = @_;
    $ctx //= run_checks($opt);
    if ( $ctx->{fails} ) {
        warnx(
'dependencies are missing; fix the FAIL lines above (or: setup.pl prepare)'
        );
        return 1;
    }
    make_path( map { "$LEGACY/$_" } @DATA_DIRS );

    my $total = 2;
    step( 1, $total, 'COBOL: cobol/builder.pl' );
    my %env;
    $env{COBOL_HOME} = $ctx->{cobol}{home} if $ctx->{cobol}{home};
    $env{COBC}       = $ctx->{cobol}{cobc} unless $ctx->{cobol}{home};
    $env{COB_CC}     = $ctx->{cobol_cc} if $ctx->{cobol_cc};
    child_perl( $P{cobol_b}, \%env ) == 0 or fatal('cobol/builder.pl failed');

    step( 2, $total, "Bridge: bridge/builder.pl (CC=$ctx->{bridge_cc})" );
    child_perl( $P{bridge_b}, { CC => $ctx->{bridge_cc} }, 'build' ) == 0
      or fatal('bridge/builder.pl failed');

    info('build finished');
    return 0;
}

# ------------------------------------------------------------------ run

# Every shared library of the executable, except the C library itself, must
# resolve inside legacy/lib (that is what makes the tree movable).
sub check_portability {
    my ($exe) = @_;
    local @ENV{@SCRUB_ENV};
    delete @ENV{@SCRUB_ENV};
    my ( $rc, $out ) =
      capture_status( '/bin/sh', '-c', 'cd "$1" && ldd "./$2" 2>&1',
        'sh', "$LEGACY/bin", $exe );
    return ( 0, "ldd failed for $exe" ) if $rc != 0;
    my ( @bad, $count );
    for my $line ( split /\n/, $out ) {
        next unless $line =~ m{^\s*(\S+)\s+=>\s+(\S+)};
        my ( $name, $path ) = ( $1, $2 );
        ( my $base = $name ) =~ s/\.so.*$//;
        next                            if $CORE_LIBS{$base};
        return ( 0, "$name not found" ) if $path eq 'not';
        $count++;
        my $real = abs_path($path) // $path;
        push @bad, "$name -> $real" unless index( $real, "$LEGACY/lib/" ) == 0;
    }
    return
      @bad ? ( 0, 'outside lib/: ' . join( ', ', @bad ) )
      : (
        1,
        $count == 1 ? '1 library resolves inside lib/'
        : "$count libraries resolve inside lib/"
      );
}

# Runs ./NAME from legacy/bin with a scrubbed environment; prints its output.
# Returns the exit code.
sub run_exe {
    my ($name) = @_;
    local @ENV{@SCRUB_ENV};
    delete @ENV{@SCRUB_ENV};
    chdir "$LEGACY/bin" or fatal("chdir $LEGACY/bin: $!");
    open( my $fh, '-|', '/bin/sh', '-c', 'exec "$@" 2>&1', 'sh', "./$name" )
      or fatal("cannot start ./$name: $!");
    while (<$fh>) { print "    $_" }
    close $fh;
    return $? == -1 ? 127 : ( $? & 127 ) ? 128 + ( $? & 127 ) : $? >> 8;
}

sub cmd_run {
    my ($names) = @_;
    my @todo = @EXECUTABLES;
    if (@$names) {
        my %want    = map  { $_         => 1 } @$names;
        my %known   = map  { $_->{name} => 1 } @EXECUTABLES;
        my @unknown = grep { !$known{$_} } @$names;
        fatal(  "unknown executable(s): @unknown (known: "
              . join( ', ', map { $_->{name} } @EXECUTABLES )
              . ')' )
          if @unknown;
        @todo = grep { $want{ $_->{name} } } @EXECUTABLES;
    }

    my @absent = grep { !-x "$LEGACY/bin/$_->{name}" } @todo;
    if (@absent) {
        warnx(  'not built: '
              . join( ', ', map { "bin/$_->{name}" } @absent )
              . ' - run: setup.pl build' );
        return 1;
    }
    make_path("$LEGACY/data/store/cobol");

    my @summary;
    my $failed = 0;
    my $n      = 0;
    for my $e (@todo) {
        $n++;
        step( $n, scalar(@todo), "bin/$e->{name}" );
        my ( $ok, $why ) = check_portability( $e->{name} );
        printf "  portability: %s (%s)\n", $ok ? 'OK' : 'FAIL', $why;

        info("running from $LEGACY/bin with a clean environment");
        my $rc = run_exe( $e->{name} );
        my ( $level, $msg );
        if ( grep { $_ == $rc } @{ $e->{ok} } ) {
            ( $level, $msg ) = ( 'ok', 'exit 0' );
        }
        elsif ( $e->{warn}{$rc} ) {
            ( $level, $msg ) = ( 'warn', "exit $rc: $e->{warn}{$rc}" );
        }
        else {
            ( $level, $msg ) = (
                'fail',
                "exit $rc"
                  . ( $EXIT_MEANING{$rc} ? ": $EXIT_MEANING{$rc}" : '' )
            );
        }
        if ( !$ok ) {    # a portability failure outranks a good exit code
            $level = 'fail';
            $msg .= "; portability: $why";
        }
        $failed++ if $level eq 'fail';
        push @summary, [ $e->{name}, $level, $msg ];
    }

    print "\n[legacy] summary\n";
    printf "  %-12s %-5s %s\n", @$_
      for map { [ $_->[0], uc $_->[1], $_->[2] ] } @summary;
    return $failed ? 1 : 0;
}

# ---------------------------------------------------------------- clean

sub cmd_clean {
    my $bad = 0;
    for my $b (
        [ cobol_b  => 'cobol/builder.pl' ],
        [ bridge_b => 'bridge/builder.pl' ]
      )
    {
        info("clean: $b->[1]");
        $bad++ if child_perl( $P{ $b->[0] }, {}, 'clean' ) != 0;
    }
    return $bad ? 1 : 0;
}

# ------------------------------------------------------------------ all

sub cmd_all {
    my ($opt) = @_;
    my $ctx = run_checks($opt);

    if ( $ctx->{fails} ) {
        unless ( $opt->{prepare} ) {
            warnx(
'dependencies are missing. Run "setup.pl prepare" or repeat with --prepare.'
            );
            return 1;
        }
        info('--prepare given: installing what is missing');
        my $rc = cmd_prepare($opt);
        return $rc if $rc;
        $ctx = run_checks($opt);
        if ( $ctx->{fails} ) {
            warnx('still missing dependencies after prepare');
            return 1;
        }
    }

    my $rc = cmd_build( $opt, $ctx );
    return $rc if $rc;
    return cmd_run( [] );
}

exit( main(@ARGV) // 0 ) unless caller;
1;
