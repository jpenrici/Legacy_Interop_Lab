#!/usr/bin/env perl
# cobol/builder.pl - builds legacy/bin/legacy_app from cobol/src/ledger.cob
#
# Toolchain (recommended, "simulated period"):
#   GnuCOBOL 3.1.2 (Dec 2020) or 3.2 (Jul 2023), built with GCC 10..13
#   (see dev/gnucobol_install.pl and dev/prepare_legacy_env.pl)
#   GnuCOBOL configured minimal: --without-db --without-xml2
#                                --without-json --without-curses
#   => libcob.so depends only on libgmp + libc, easy to ship in lib/.
#
# Env overrides:  COBC=/path/to/cobc GCC=gcc-10 (or CC=gcc-10 / COB_CC=gcc-10)
#                 COBOL_HOME=/opt/gnucobol-3.1.2  (uses $COBOL_HOME/bin/cobc)
#                 example: GCC=gcc-13 perl builder.pl [clean]
#
# Usage:          perl builder.pl [clean]
use strict;
use warnings;
use Cwd            qw(abs_path);
use File::Basename qw(dirname basename);
use File::Copy     qw(copy);
use File::Path     qw(make_path);

my $root = abs_path( dirname(__FILE__) . '/..' );
my $src  = "$root/cobol/src/ledger.cob";
my $bin  = "$root/bin";
my $lib  = "$root/lib";
my $exe  = "$bin/legacy_app";

sub die_msg { print STDERR "builder: @_\n"; exit 1 }

if ( @ARGV && $ARGV[0] eq 'clean' ) {
    unlink $exe;
    unlink glob("$lib/lib*.so*");
    print "builder: cleaned\n";
    exit 0;
}

# --- configure C compiler environment---------------------------------
$ENV{COB_CC} =$ENV{GCC} // $ENV{CC} //$ENV{COB_CC};

# --- locate cobc -----------------------------------------------------
my $cobc = $ENV{COBC};
$cobc = "$ENV{COBOL_HOME}/bin/cobc" if !$cobc && $ENV{COBOL_HOME};
if ( !$cobc ) {
    ($cobc) = grep { -x $_ } map { "$_/cobc" } split /:/, $ENV{PATH} // '';
}
die_msg("cobc not found (set COBC or COBOL_HOME)") unless $cobc && -x $cobc;

my ($ver) = ( `"$cobc" --version 2>&1` =~ /\(GnuCOBOL\)\s+(\d+\.\d+)/ );
die_msg("cannot read cobc version") unless $ver;
print "builder: cobc $ver at $cobc\n";
print "builder: WARNING only GnuCOBOL 3.1 and 3.2 are expected to work\n"
  unless $ver =~ /^3\.[12]$/;
print "builder: NOTE 3.2 is not yet verified with this project; compare the\n",
  "builder:      md5 of data/store/cobol/cb_data.dat against a 3.1.2 build\n"
  if $ver eq '3.2';
print "builder: C compiler = ",
  ( $ENV{COB_CC} // ( `"$cobc" --info` =~ /COB_CC\s*:\s*(\S+)/ )[0] // '?' ),
  "\n";

die_msg("source not found: $src") unless -f $src;
make_path( $bin, $lib );

# --- compile ---------------------------------------------------------
# -Q passes the linker option: the executable finds ../lib at run time,
# wherever the legacy/ tree is moved to (no LD_LIBRARY_PATH needed).
# DT_RPATH (not RUNPATH) is used on purpose: it also applies to libcob's
# own dependency (libgmp), RUNPATH would not.
my @cmd = (
    $cobc, '-x', '-fixed', '-std=default', '-Wall', '-O2',
    '-Q',  '-Wl,--disable-new-dtags,-rpath,$ORIGIN/../lib',
    '-o',  $exe, $src,
);
print "builder: ", join( ' ', map { /\s|\$/ ? "'$_'" : $_ } @cmd ), "\n";
system(@cmd) == 0 or die_msg("cobc failed");

# --- bundle runtime libraries (libcob, libgmp) into legacy/lib -------
my %skip = map { $_ => 1 }
  qw(linux-vdso.so.1 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0
  librt.so.1 libgcc_s.so.1 ld-linux-x86-64.so.2 ld-linux-aarch64.so.1);

# resolve against the libcob that cobc linked (its -L dir), not whatever
# the system loader finds first
my ($cobdir) = ( `"$cobc" --info` =~ /COB_LIBS\s*:.*?-L(\S+)/ );
my $ldd = do {
    local $ENV{LD_LIBRARY_PATH} = $cobdir // '';
    `ldd "$exe" 2>&1`;
};
for my $line ( split /\n/, $ldd ) {
    next unless $line =~ /^\s*(\S+)\s+=>\s+(\/\S+)/;
    my ( $name, $path ) = ( $1, $2 );
    next if $skip{$name};
    my $dest = "$lib/$name";
    next if abs_path($path) eq ( -e $dest ? abs_path($dest) : '' );
    unlink $dest;
    copy( abs_path($path), $dest ) or die_msg("copy $path: $!");
    print "builder: bundled $name\n";
}

# --- verify: with a clean environment, libs must resolve to ../lib ---
local $ENV{LD_LIBRARY_PATH} = '';
my $check = `cd "$bin" && ldd ./legacy_app 2>&1`;
for my $need (qw(libcob libgmp)) {
    $check =~ m{\b\Q$need\E\.so\.\d+\s+=>\s+(\S+)}
      or die_msg("$need not resolved");
    my $got = abs_path($1) // $1;
    die_msg("$need resolves outside lib/: $got")
      unless index( $got, "$lib/" ) == 0;
}
print "builder: OK -> $exe\n";
