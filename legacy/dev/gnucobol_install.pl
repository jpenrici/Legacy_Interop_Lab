#!/usr/bin/env perl
# legacy/dev/gnucobol_install.pl

=head1 NAME

gnucobol_install.pl - build GnuCOBOL from source into a private prefix under /opt

=head1 SYNOPSIS

  gnucobol_install.pl [install] [options]     build and install (default)
  gnucobol_install.pl verify    [options]     smoke-test an existing install
  gnucobol_install.pl status                  list known installs
  gnucobol_install.pl uninstall [options]     remove an install made by this script

  Options:
    --version V     GnuCOBOL version: 3.2 (default) or 3.1.2
    --prefix DIR    install prefix (default /opt/gnucobol-V)
    --cc CMD        C compiler used to build GnuCOBOL (default gcc-13)
    --jobs N        parallel jobs for make (default: number of CPUs)
    --no-check      skip "make check" (the full test suite, slow)
    --yes, -y       answer "yes" to every question (non-interactive)
    --skip-verify   do NOT verify the GPG signature (offline/testing only)
    --workdir DIR   download/build directory (reused; kept after the run)
    --keep-work     keep the temporary work directory
    --help, -h      this text

=head1 DESCRIPTION

Builds the GnuCOBOL release tarball with the same minimal configuration the
legacy project relies on (C<--without-db --without-xml2 --without-json
--without-curses>), so that C<libcob> depends only on libgmp and libc and can
be copied into C<legacy/lib>.

Each version gets its own prefix, so several versions coexist with each
other and with the distribution package (/usr). Nothing is added to PATH or
to ld.so.conf; select a version per shell with C<COBOL_HOME>.

Safety measures:

=over 4

=item * download, GPG check, configure and make run as the invoking user;
root (sudo) is used only for apt and for copying the staged install into the
prefix

=item * the tarball signature is verified against the GNU keyring and the
run aborts unless gpg reports a good, valid signature

=item * install is staged (C<make install DESTDIR=...>) and then copied, so a
failed build never leaves a half-written prefix

=item * an existing prefix is never overwritten; uninstall removes only
prefixes that carry the C<.legacy-dev> marker written by this script

=item * all build output goes to a log file; its tail is shown on failure

=back

Offline use: put C<gnucobol-V.tar.xz> (and, to verify, C<.sig> plus
C<gnu-keyring.gpg>) in the directory given by C<--workdir>; existing files
are reused instead of downloaded.

=head1 EXIT STATUS

0 success (or nothing to do), 1 failure, 2 usage error.

=head1 EXAMPLES

  perl gnucobol_install.pl --version 3.1.2 --no-check
  perl gnucobol_install.pl verify --version 3.2
  perl gnucobol_install.pl uninstall --version 3.1.2

=cut

use strict;
use warnings;
use FindBin qw($RealBin);
use lib $RealBin;
use Getopt::Long qw(GetOptionsFromArray);
use Pod::Usage;
use File::Temp     qw(tempdir);
use File::Path     qw(make_path);
use File::Basename qw(basename);
use Cwd            qw(abs_path);
use POSIX          qw(strftime);
use LegacyDev      qw(
  info warnx fatal step run run_logged capture capture_status can_run
  is_root path_writable priv_for confirm gcc_major apt_ensure
  sha256_file read_kv
);

# ---------------------------------------------------------------- data

# Releases this script knows how to handle.
my %KNOWN = (
    '3.1.2' => 'gnucobol-3.1.2.tar.xz',    # verified with this project
    '3.2'   => 'gnucobol-3.2.tar.xz',      # not yet verified with this project
);
my $BASE_URL    = 'https://ftp.gnu.org/gnu/gnucobol';
my $KEYRING_URL = 'https://ftp.gnu.org/gnu/gnu-keyring.gpg';

# Same minimal build the project is designed around.
my @CONFIGURE_FLAGS =
  qw(--without-db --without-xml2 --without-json --without-curses --disable-nls --disable-static);

my @BUILD_PKGS =
  qw(build-essential libgmp-dev curl xz-utils gnupg ca-certificates);
my $MARKER = '.legacy-dev';

# Shared libraries a minimal libcob is allowed to need.
my %ALLOWED_DEPS = map { $_ => 1 } qw(
  libgmp libc libm libdl libpthread librt libgcc_s ld-linux-x86-64 ld-linux-aarch64 linux-vdso
);

# ---------------------------------------------------------------- main

sub main {
    my @args = @_;
    my %opt  = ( version => '3.2', cc => 'gcc-13', check => 1 );

    GetOptionsFromArray(
        \@args,        \%opt,       'version=s', 'prefix=s',
        'cc=s',        'jobs=i',    'check!',    'yes|y',
        'skip-verify', 'workdir=s', 'keep-work', 'help|h',
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
    ) unless $cmd =~ /^(install|verify|status|uninstall)$/;

    $LegacyDev::ASSUME_YES = 1 if $opt{yes};
    umask 022;    # installed files must be readable by everybody

    return cmd_status() if $cmd eq 'status';

    fatal(  "unsupported version '$opt{version}' (known: "
          . join( ', ', sort keys %KNOWN )
          . ')' )
      unless $KNOWN{ $opt{version} };
    $opt{prefix} //= "/opt/gnucobol-$opt{version}";
    check_prefix_syntax( $opt{prefix} );

    return cmd_install( \%opt )   if $cmd eq 'install';
    return cmd_verify( \%opt )    if $cmd eq 'verify';
    return cmd_uninstall( \%opt ) if $cmd eq 'uninstall';
}

# A conservative prefix: absolute, plain characters, no "..", not too shallow.
sub check_prefix_syntax {
    my ($p) = @_;
    fatal("prefix must be an absolute path made of [A-Za-z0-9._/+-]: '$p'")
      unless $p =~ m{^/[A-Za-z0-9._+/-]+$} && $p !~ m{(^|/)\.\.(/|$)};
    fatal("prefix is too shallow: '$p'")
      if ( $p =~ tr{/}{} ) < 2 && $p !~ m{^/opt/};
}

# ------------------------------------------------------------- status

sub installed_cobc_version {
    my ($prefix) = @_;
    my $cobc = "$prefix/bin/cobc";
    return unless -x $cobc;
    my ( $rc, $out ) = capture_status( $cobc, '--version' );
    return ( $rc == 0 && $out =~ /\(GnuCOBOL\)\s+(\S+)/ ) ? $1 : undef;
}

sub cmd_status {
    info('GnuCOBOL installs (default prefixes):');
    for my $v ( sort keys %KNOWN ) {
        my $prefix = "/opt/gnucobol-$v";
        my $got    = installed_cobc_version($prefix);
        if ( !defined $got ) {
            info( sprintf( '  %-6s not installed (%s)', $v, $prefix ) );
            next;
        }
        my $kv = read_kv("$prefix/$MARKER");
        my $by =
          $kv
          ? "managed, cc=$kv->{cc}, signature=$kv->{signature}"
          : 'NOT managed by this script';
        info( sprintf( '  %-6s cobc %s at %s [%s]', $v, $got, $prefix, $by ) );
    }
    return 0;
}

# ------------------------------------------------------------ install

sub cmd_install {
    my ($o)    = @_;
    my $prefix = $o->{prefix};
    my $ver    = $o->{version};
    my $total  = 8;

    # Never overwrite: abort when already installed, refuse unknown content.
    if ( -e $prefix ) {
        if ( defined( my $got = installed_cobc_version($prefix) ) ) {
            info("GnuCOBOL $got is already installed in $prefix - nothing to do"
            );
            info("(to rebuild: gnucobol_install.pl uninstall --version $ver)");
            return 0;
        }
        my @content =
          -d $prefix
          ? ( glob("$prefix/*"), glob("$prefix/.[!.]*") )
          : ($prefix);
        fatal(
            "$prefix exists but is not a GnuCOBOL install; refusing to touch it"
        ) if @content;
    }

    # Clean environment: stray COB_*/FLAGS variables would leak into the build.
    delete @ENV{
        qw(CFLAGS CPPFLAGS LDFLAGS LIBS COB_CFLAGS COB_LDFLAGS COB_CC COBC COBOL_HOME)
    };
    $ENV{LC_ALL} = 'C';

    step( 1, $total, "Checking the toolchain ($o->{cc})" );

    # Fail early if the final copy will need root and we cannot get it.
    fatal("$prefix is not writable and neither root nor sudo is available")
      if !path_writable($prefix) && !is_root() && !can_run('sudo');
    my $cc_path = can_run( $o->{cc} )
      or fatal("C compiler '$o->{cc}' not found (try: prepare_legacy_env.pl)");
    my $cc_major = gcc_major( $o->{cc} )
      // fatal("cannot read the version of $o->{cc}");
    info("using $cc_path (GCC $cc_major)");
    warnx(
'running as root: the build itself does not need it; prefer a normal user with sudo'
    ) if is_root();
    apt_ensure(@BUILD_PKGS) if can_run('dpkg-query');
    for my $tool (qw(make tar xz curl gpg)) {
        can_run($tool) or fatal("required tool not found: $tool");
    }

    my $work = $o->{workdir};
    if ($work) {
        make_path( $work, { mode => 0700 } );
        $work = abs_path($work);
    }
    else {
        $work = tempdir( 'gnucobol_build_XXXXXX', TMPDIR => 1, CLEANUP => 0 );
    }
    my $keep = $o->{'keep-work'} || $o->{workdir};
    my $log  = "$work/build.log";
    info("work directory: $work (log: $log)");

    my $tarball = $KNOWN{$ver};
    my $tar     = "$work/$tarball";

    step( 2, $total, 'Downloading the release' );
    fetch( "$BASE_URL/$tarball", $tar, $log );
    my $sha = sha256_file($tar);
    info("sha256($tarball) = $sha");

    step( 3, $total, 'Verifying the GPG signature' );
    my $signature = 'SKIPPED';
    if ( $o->{'skip-verify'} ) {
        warnx(
'signature verification SKIPPED (--skip-verify): the tarball is NOT authenticated'
        );
    }
    else {
        fetch( "$BASE_URL/$tarball.sig", "$tar.sig",              $log );
        fetch( $KEYRING_URL,             "$work/gnu-keyring.gpg", $log );
        my $fpr = verify_signature( "$work/gnu-keyring.gpg", "$tar.sig", $tar,
            "$work/gnupg" );
        fatal(
"signature check FAILED for $tarball - not building (see gpg output above)"
        ) unless $fpr;
        info("good signature, key fingerprint $fpr");
        $signature = "verified:$fpr";
    }

    step( 4, $total, 'Extracting' );
    my $src = "$work/src";
    make_path($src);
    run_logged( $log, 'tar', '-xf', $tar, '-C', $src, '--no-same-owner' );
    my @dirs = grep { -d $_ } glob("$src/*");
    fatal("expected a single directory in the tarball, found: @dirs")
      unless @dirs == 1;
    my $srcdir = $dirs[0];

    my $jobs  = $o->{jobs} || cpu_count();
    my $build = "$work/build";
    make_path($build);

    step( 5, $total, "Configuring (out-of-tree, CC=$o->{cc})" );
    chdir $build or fatal("chdir $build: $!");
    run_logged( $log, "$srcdir/configure", "CC=$o->{cc}", "--prefix=$prefix",
        @CONFIGURE_FLAGS );

    step( 6, $total, "Compiling (make -j$jobs)" );
    run_logged( $log, 'make', "-j$jobs" );
    if ( $o->{check} ) {
        info(
'running the test suite (make check) - this takes a while; --no-check skips it'
        );
        run_logged( $log, 'make', 'check', "TESTSUITEFLAGS=-j$jobs" );
    }
    else {
        warnx('test suite skipped (--no-check)');
    }

    step( 7, $total, "Installing into $prefix" );
    my $stage = "$work/stage";
    run_logged( $log, 'make', 'install', "DESTDIR=$stage" );
    my $staged = "$stage$prefix";
    -d $staged or fatal("staged install not found at $staged");
    write_marker( "$staged/$MARKER", $ver, $o->{cc}, $cc_major, $sha,
        $signature );
    priv_for( $prefix, 'mkdir', '-p', '--', $prefix );
    priv_for( $prefix, 'cp', '-a', '--no-preserve=ownership', '--',
        "$staged/.", "$prefix/." );
    chdir '/';

    step( 8, $total, 'Verifying the installation' );
    verify_install( $prefix, $ver, $o->{cc} );

    if   ($keep) { info("work directory kept: $work") }
    else         { run( 'rm', '-rf', '--one-file-system', '--', $work ) }

    info("GnuCOBOL $ver installed in $prefix");
    info("use it per shell:  export COBOL_HOME=$prefix");
    return 0;
}

sub cpu_count {
    my ( $rc, $out ) = capture_status('nproc');
    return ( $rc == 0 && $out =~ /^(\d+)/ && $1 > 0 ) ? $1 : 2;
}

sub fetch {
    my ( $url, $dest, $log ) = @_;
    if ( -s $dest ) {
        info( 'reusing ' . basename($dest) );
        return;
    }
    run_logged(
        $log,            'curl',         '--fail',     '--location',
        '--silent',      '--show-error', '--proto',    '=https',
        '--proto-redir', '=https',       '--tlsv1.2',  '--retry',
        '3',             '--output',     "$dest.part", $url
    );
    rename( "$dest.part", $dest ) or fatal("rename $dest.part: $!");
    return;
}

# Returns the signer fingerprint when gpg reports a GOOD and VALID signature
# and nothing suspicious (bad/expired/revoked/unknown key); undef otherwise.
sub verify_signature {
    my ( $keyring, $sig, $file, $home ) = @_;
    make_path( $home, { mode => 0700 } );
    chmod 0700, $home;
    my ( $rc, $out ) =
      capture_status( 'gpg', '--homedir', $home, '--batch',
        '--no-default-keyring',
        '--keyring', $keyring, '--status-fd', '1', '--verify', $sig, $file );
    my %seen;
    $seen{$1}++ while $out =~ /^\[GNUPG:\] (\w+)/mg;
    for my $bad (qw(BADSIG ERRSIG EXPSIG EXPKEYSIG REVKEYSIG NO_PUBKEY)) {
        if ( $seen{$bad} ) {
            warnx("gpg reported $bad");
            return;
        }
    }
    return unless $rc == 0 && $seen{GOODSIG} && $seen{VALIDSIG};
    return $out =~ /^\[GNUPG:\] VALIDSIG ([0-9A-Fa-f]{40})/m ? $1 : undef;
}

sub write_marker {
    my ( $file, $ver, $cc, $cc_major, $sha, $signature ) = @_;
    open( my $fh, '>', $file ) or fatal("cannot write $file: $!");
    print {$fh} join( "\n",
        "version=$ver",
        "cc=$cc",
        "cc_major=$cc_major",
        'installed=' . strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime ),
        "configure=@CONFIGURE_FLAGS",
        "source_sha256=$sha",
        "signature=$signature",
        'by=gnucobol_install.pl',
        '' );
    close $fh or fatal("cannot write $file: $!");
}

# -------------------------------------------------------------- verify

sub cmd_verify {
    my ($o) = @_;
    verify_install( $o->{prefix}, $o->{version}, $o->{cc} );
    return 0;
}

# Smoke test of an installed prefix: version, compile+run, minimal deps.
sub verify_install {
    my ( $prefix, $ver, $cc ) = @_;
    my $cobc = "$prefix/bin/cobc";
    -x $cobc or fatal("$cobc not found - is GnuCOBOL $ver installed there?");

    my $got = installed_cobc_version($prefix)
      // fatal('cannot read cobc --version');
    fatal("version mismatch: wanted $ver, cobc reports $got")
      unless index( $got, $ver ) == 0;
    info("cobc $got");

    my $info = capture( $cobc, '--info' );
    my ($cob_cc) = $info =~ /^COB_CC\s*:\s*(\S+)/m;
    info( 'COB_CC (compiler cobc will call): ' . ( $cob_cc // '?' ) );
    warnx("cobc will call '$cob_cc', not '$cc'")
      if $cob_cc && $cc && $cob_cc ne $cc;

    my $tmp = tempdir( 'gnucobol_verify_XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    open( my $fh, '>', "$tmp/hello.cob" )
      or fatal("cannot write test program: $!");
    print {$fh} <<'COBOL';
       IDENTIFICATION DIVISION.
       PROGRAM-ID. HELLO.
       PROCEDURE DIVISION.
           DISPLAY "GNUCOBOL OK".
           STOP RUN.
COBOL
    close $fh;
    run( $cobc, '-x', '-fixed', '-o', "$tmp/hello", "$tmp/hello.cob" );
    {
        local $ENV{LD_LIBRARY_PATH} = "$prefix/lib";
        my $out = capture("$tmp/hello");
        fatal("test program printed unexpected output: $out")
          unless $out =~ /^GNUCOBOL OK$/m;
    }
    info('compile + run: GNUCOBOL OK');

    # The project bundles libcob into legacy/lib: keep its dependencies minimal.
    my ($libcob) = grep { -e $_ } glob("$prefix/lib/libcob.so");
    $libcob or fatal("libcob.so not found under $prefix/lib");
    my $ldd = capture( 'ldd', $libcob );
    my @extra;
    while ( $ldd =~ /^\s*(\S+?)\.so[.\d]*\s+=>/mg ) {
        push @extra, $1 unless $ALLOWED_DEPS{$1};
    }
    if (@extra) {
        warnx(
            'libcob has extra dependencies (not relocatable via legacy/lib): '
              . join( ', ', @extra ) );
    }
    else {
        info('libcob dependencies are minimal (libgmp + libc)');
    }
    return 1;
}

# ----------------------------------------------------------- uninstall

sub cmd_uninstall {
    my ($o) = @_;
    my $prefix = $o->{prefix};
    unless ( -e $prefix ) {
        info("$prefix does not exist - nothing to do");
        return 0;
    }
    my $real = abs_path($prefix) // fatal("cannot resolve $prefix");
    fatal("$prefix resolves to $real (symlink?); refusing to remove it")
      unless $real eq $prefix;
    fatal("refusing to remove '$prefix': name must start with 'gnucobol-'")
      unless basename($prefix) =~ /^gnucobol-[0-9]/;
    my $kv = read_kv("$prefix/$MARKER")
      or fatal(
"$prefix has no $MARKER marker: not created by this script; remove it manually if you are sure"
      );
    info(
"this removes $prefix (GnuCOBOL $kv->{version}, installed $kv->{installed})"
    );
    confirm('Remove it?') or do { info('cancelled'); return 0 };
    priv_for( $prefix, 'rm', '-rf', '--one-file-system', '--', $prefix );
    info('removed (apt packages and gcc are left untouched)');
    return 0;
}

# ---------------------------------------------------------------- go

exit( main(@ARGV) // 0 ) unless caller;
1;
