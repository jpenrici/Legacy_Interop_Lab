package LegacyDev;
# legacy/dev/LegacyDev.pm

=head1 NAME

LegacyDev - small helpers shared by the legacy/dev scripts

=head1 DESCRIPTION

Logging, safe command execution (list form only, never a shell string),
privilege handling (sudo only when needed), confirmation prompts and a few
Debian package helpers. Core Perl modules only.

=cut

use strict;
use warnings;
use Exporter 'import';
use Digest::SHA ();

our @EXPORT_OK = qw(
  info warnx fatal step
  run run_logged capture capture_status can_run
  is_root path_writable priv priv_for
  confirm gcc_major os_release pkg_missing apt_ensure
  sha256_file read_kv
);

# Set to 1 by --yes: every confirm() answers "yes".
our $ASSUME_YES = 0;

# ------------------------------------------------------------- messages

sub info  { print STDOUT "[legacy] @_\n" }
sub warnx { print STDERR "[legacy] WARNING: @_\n" }

sub fatal {
    print STDERR "[legacy] ERROR: @_\n";
    exit 1;
}

sub step {
    my ( $n, $total, $text ) = @_;
    print STDOUT "\n[legacy] ($n/$total) $text\n";
}

# ----------------------------------------------------------- execution

sub _describe_status {
    my ($st) = @_;
    return 'could not be started: ' . ( $! || 'unknown error' ) if $st == -1;
    return 'killed by signal ' .      ( $st & 127 )             if $st & 127;
    return 'exit status ' .           ( $st >> 8 );
}

# Runs a command (list form). Dies (exit 1) on failure.
sub run {
    my @cmd = @_;
    info( '$ ' . join( ' ', @cmd ) );
    system(@cmd) == 0
      or fatal( "command failed (" . _describe_status($?) . "): @cmd" );
    return 1;
}

# Runs a command with stdout+stderr appended to $log. On failure shows the
# last lines of the log and dies. Still list form: the tiny sh -c wrapper
# only performs the redirection and receives the command as arguments.
sub run_logged {
    my ( $log, @cmd ) = @_;
    if ( open( my $fh, '>>', $log ) ) {
        print {$fh} "\n\$ @cmd\n";
        close $fh;
    }
    local $ENV{LEGACY_LOG} = $log;
    my $rc =
      system( '/bin/sh', '-c', 'exec "$@" >>"$LEGACY_LOG" 2>&1', 'sh', @cmd );
    return 1 if $rc == 0;
    _show_tail( $log, 25 );
    fatal(  "command failed ("
          . _describe_status($?)
          . "): @cmd\n[legacy] full log: $log" );
}

sub _show_tail {
    my ( $file, $n ) = @_;
    open( my $fh, '<', $file ) or return;
    my @lines = <$fh>;
    close $fh;
    splice( @lines, 0, @lines - $n ) if @lines > $n;
    print STDERR "----- last lines of $file -----\n", @lines, "-----\n";
}

# Returns ($exit_code, $stdout). Never dies on a non-zero exit.
sub capture_status {
    my @cmd = @_;
    open( my $fh, '-|', @cmd ) or return ( -1, '' );
    local $/;
    my $out = <$fh>;
    $out //= '';
    close $fh;
    return ( $? == -1 ? -1 : ( $? & 127 ? 128 + ( $? & 127 ) : $? >> 8 ),
        $out );
}

# Returns stdout; dies if the command fails.
sub capture {
    my @cmd = @_;
    my ( $rc, $out ) = capture_status(@cmd);
    fatal("command failed (exit $rc): @cmd") if $rc != 0;
    return $out;
}

# Full path of an executable found in PATH (or given as a path), else undef.
sub can_run {
    my ($cmd) = @_;
    if ( $cmd =~ m{/} ) {
        return ( -f $cmd && -x _ ) ? $cmd : undef;
    }
    for my $dir ( split /:/, $ENV{PATH} // '' ) {
        next if $dir eq '';
        my $p = "$dir/$cmd";
        return $p if -f $p && -x _;
    }
    return;
}

# ---------------------------------------------------------- privileges

sub is_root { return $> == 0 }

# True if $path (or its nearest existing parent) is writable by us.
sub path_writable {
    my ($path) = @_;
    $path =~ s{/+$}{};
    while ( length $path && !-e $path ) {
        $path =~ s{/[^/]*$}{};
    }
    $path = '/' unless length $path;
    return -w $path ? 1 : 0;
}

# Runs a command as root: directly when already root, through sudo otherwise.
sub priv {
    my @cmd = @_;
    unless ( is_root() ) {
        can_run('sudo')
          or fatal(
"root privileges are needed for: @cmd\n[legacy] sudo not found - run this script as root or install sudo"
          );
        unshift @cmd, 'sudo', '--';
    }
    return run(@cmd);
}

# Like priv(), but skips sudo when $path is writable (e.g. a prefix in $HOME).
sub priv_for {
    my ( $path, @cmd ) = @_;
    return path_writable($path) ? run(@cmd) : priv(@cmd);
}

# --------------------------------------------------------------- prompt

sub confirm {
    my ($question) = @_;
    return 1 if $ASSUME_YES;
    fatal(
        "\"$question\" needs an answer but stdin is not a terminal; use --yes")
      unless -t STDIN;
    while (1) {
        print STDOUT "[legacy] $question [y/N] ";
        my $a = <STDIN>;
        return 0 unless defined $a;
        chomp $a;
        return 1 if $a =~ /^y(es)?$/i;
        return 0 if $a =~ /^(n(o)?)?$/i;
        print STDOUT "Please answer y or n.\n";
    }
}

# ------------------------------------------------------- system queries

# GCC major version of a compiler command ("gcc-13" -> 13), undef if unusable.
sub gcc_major {
    my ($cc) = @_;
    can_run($cc) or return;
    my ( $rc, $out ) = capture_status( $cc, '-dumpversion' );
    return if $rc != 0;
    return $out =~ /^(\d+)/ ? $1 : undef;
}

sub read_kv {
    my ($file) = @_;
    my %kv;
    open( my $fh, '<', $file ) or return;
    while (<$fh>) {
        chomp;
        $kv{$1} = $2 if /^([A-Za-z0-9_]+)=(.*)$/;
    }
    close $fh;
    return \%kv;
}

sub os_release { return read_kv('/etc/os-release') || {} }

sub sha256_file {
    my ($file) = @_;
    return Digest::SHA->new(256)->addfile($file)->hexdigest;
}

# -------------------------------------------------------- Debian packages

# Subset of @pkgs that dpkg does not report as installed.
sub pkg_missing {
    my @pkgs = @_;
    my @missing;
    for my $p (@pkgs) {
        my ( $rc, $out ) =
          capture_status( 'dpkg-query', '-W', '-f=${db:Status-Status}', $p );
        push @missing, $p unless $rc == 0 && $out eq 'installed';
    }
    return @missing;
}

# Installs whatever is missing (after asking). Dies if it cannot.
sub apt_ensure {
    my @want = @_;
    can_run('dpkg-query') && can_run('apt-get')
      or
      fatal("apt/dpkg not available on this system; install manually: @want");
    my @missing = pkg_missing(@want);
    return 1 unless @missing;
    info("missing packages: @missing");
    confirm('Install them with apt-get?')
      or fatal('aborted: required packages are missing');
    priv( 'apt-get', 'update' );
    priv( 'env', 'DEBIAN_FRONTEND=noninteractive',
        'apt-get', 'install', '-y', '--no-install-recommends', @missing );
    my @still = pkg_missing(@missing);
    fatal("still missing after apt-get: @still") if @still;
    return 1;
}

1;
