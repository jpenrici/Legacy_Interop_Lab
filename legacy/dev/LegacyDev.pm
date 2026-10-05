package LegacyDev;

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
use File::Find  ();

our @EXPORT_OK = qw(
  info warnx fatal step
  run run_logged capture capture_status can_run
  is_root path_writable owned_by_me
  shell_quote priv_method priv_describe priv_batch priv
  confirm gcc_major os_release pkg_missing apt_ensure
  sha256_file read_kv
);

# Set to 1 by --yes: every confirm() answers "yes".
our $ASSUME_YES = 0;

# Requested privilege method (--priv): auto | sudo | su | print
our $PRIV_REQUEST = 'auto';

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
#
# Methods, in the order auto-detection tries them:
#   root   already root: commands run directly
#   sudo   user can sudo (in group sudo/wheel/admin, or passwordless)
#   su     ask the root password (needs a terminal)
#   print  no automatic way: print the exact commands for the user to run
#          as root, wait for Enter, and check the result (or exit 3 when
#          there is no terminal)
# Privileged work is grouped into few batches so the password is asked
# as few times as possible.

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

# True if every entry under $dir (and $dir itself) belongs to us.
sub owned_by_me {
    my ($dir) = @_;
    return 0 unless -d $dir;
    my $ok = 1;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                my @st = lstat($File::Find::name);
                $ok = 0 if !@st || $st[4] != $>;
            },
        },
        $dir
    );
    return $ok;
}

# POSIX-shell single quoting: safe for any string.
sub shell_quote {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# Like system() but silences stderr; returns the exit code.
sub _quiet_status {
    my @cmd = @_;
    open( my $old, '>&', \*STDERR ) or return -1;
    open( STDERR,  '>',  '/dev/null' );
    my $rc = system(@cmd);
    open( STDERR, '>&', $old );
    close $old;
    return $rc == -1 ? -1 : $? >> 8;
}

sub _in_group {
    my @want = @_;
    my ( $rc, $out ) = capture_status( 'id', '-Gn' );
    return 0 if $rc != 0;
    my %have = map { $_ => 1 } split ' ', $out;
    return scalar grep { $have{$_} } @want;
}

# sudo installed AND likely to work for this user (no password prompt needed
# to find out: group membership or a passwordless/cached rule).
sub _sudo_usable {
    can_run('sudo') or return 0;
    return 1 if _quiet_status( 'sudo', '-n', 'true' ) == 0;
    return _in_group(qw(sudo wheel admin)) ? 1 : 0;
}

my $_method;

sub priv_method {
    return $_method if defined $_method;
    my $req = $PRIV_REQUEST;
    if ( is_root() ) { return $_method = 'root' }
    if ( $req eq 'sudo' ) {
        can_run('sudo')
          or fatal('--priv sudo requested but sudo is not installed');
        return $_method = 'sudo';
    }
    if ( $req eq 'su' ) {
        can_run('su') or fatal('--priv su requested but su is not available');
        return $_method = 'su';
    }
    return $_method = 'print' if $req eq 'print';
    return $_method = 'sudo'  if _sudo_usable();
    return $_method = 'su'    if can_run('su') && -t STDIN;
    return $_method = 'print';
}

sub priv_describe {
    my %text = (
        root  => 'root (privileged commands run directly)',
        sudo  => 'sudo (your password may be asked)',
        su    => 'su (the root password will be asked)',
        print =>
'no automatic method - privileged commands will be printed for you to run as root',
    );
    return $text{ priv_method() };
}

# One shell line for `su -c`: absolute command paths and a fixed PATH, so
# root's environment does not matter.
sub _su_script {
    my @cmds = @_;
    my @parts;
    for my $c (@cmds) {
        my @c   = @$c;
        my $abs = can_run( $c[0] ) // fatal("cannot find '$c[0]' in PATH");
        $c[0] = $abs;
        push @parts, join( ' ', map { shell_quote($_) } @c );
    }
    return
'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH; '
      . join( ' && ', @parts );
}

sub _printable {
    my ($c) = @_;
    my @c   = @$c;
    my $abs = can_run( $c[0] );
    $c[0] = $abs if $abs;
    return join( ' ',
        map { $_ =~ m{^[A-Za-z0-9_@%+=:,./-]+$} ? $_ : shell_quote($_) } @c );
}

# Runs a batch of commands with root privileges.
#   priv_batch( why => 'text', cmds => [ [cmd, args...], ... ],
#               check => sub { ... true when the work is really done } );
# Returns 'done', or 'pending' when the commands were only printed and there
# is no terminal to wait on (the caller should stop and return exit code 3).
sub priv_batch {
    my (%a)    = @_;
    my @cmds   = @{ $a{cmds} };
    my $method = priv_method();

    if ( $method eq 'root' ) {
        run(@$_) for @cmds;
        return 'done';
    }
    if ( $method eq 'sudo' ) {
        info("using sudo for: $a{why}");
        run( 'sudo', '--', @$_ ) for @cmds;
        return 'done';
    }
    if ( $method eq 'su' ) {
        info("using su for: $a{why}");
        info( 'as root, will run: ' . _printable($_) ) for @cmds;
        my $rc =
          system( 'su', '-s', '/bin/sh', '-c', _su_script(@cmds), 'root' );
        fatal(  'su failed ('
              . _describe_status($?)
              . ') - wrong password or su not allowed' )
          if $rc != 0;
        return 'done';
    }

    # print: manual hand-off
    print STDOUT "\n[legacy] Root privileges are needed ($a{why}).\n",
"[legacy] No automatic method is available. Run as root (for example in another\n",
      "[legacy] terminal, after 'su -'):\n\n";
    print STDOUT '    ', _printable($_), "\n" for @cmds;
    print STDOUT "\n";
    if ( -t STDIN ) {
        print STDOUT '[legacy] Press Enter when done (Ctrl-C to abort) ';
        my $x = <STDIN>;
        if ( $a{check} && !$a{check}->() ) {
            fatal('the privileged step does not look complete; aborting');
        }
        return 'done';
    }
    return 'pending';
}

# Single privileged command.
sub priv {
    my @cmd = @_;
    my $r   = priv_batch( why => $cmd[0], cmds => [ \@cmd ] );
    fatal("privileged command not executed (run it as root): @cmd")
      if $r eq 'pending';
    return 1;
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
# Exits with 3 when the commands could only be printed (no terminal).
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
    my $r = priv_batch(
        why  => 'install packages: ' . join( ' ', @missing ),
        cmds => [
            [ 'apt-get', 'update' ],
            [
                'env',     'DEBIAN_FRONTEND=noninteractive',
                'apt-get', 'install',
                '-y',      '--no-install-recommends',
                @missing
            ],
        ],
        check => sub { my @m = pkg_missing(@missing); return !@m },
    );
    if ( $r eq 'pending' ) {
        info('run the commands above as root, then run this script again');
        exit 3;
    }
    my @still = pkg_missing(@missing);
    fatal("still missing after apt-get: @still") if @still;
    return 1;
}

1;
