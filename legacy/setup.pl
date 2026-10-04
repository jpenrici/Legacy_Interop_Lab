#!/usr/bin/env perl
# Usage: setup.pl check | venv | init | clean [--all]
use v5.40;

use Cwd qw(abs_path);
use File::Find;
use File::Path qw(make_path remove_tree);
use FindBin    qw($Bin);
use Getopt::Long;
use IPC::Open3;

# --- main -----------------------------------------------------------------

die "Refusing to run as root (uid 0).\n" if $< == 0 || $> == 0;

my $root = abs_path($Bin) // die "cannot resolve root\n";
my ( $cmd, @args ) = @ARGV;

my %run = (
    check => \&check,
    venv  => \&venv,
    init  => \&init,
    clean => \&clean
);
my $fn = $run{ $cmd // '' }
  or die "usage: setup.pl " . join( ' | ', sort keys %run ) . "\n";
exit( $fn->(@args) // 0 );

# --- helpers --------------------------------------------------------------

# First output line (stdout+stderr) of a command, or undef if it is missing or
# exits non-zero. List form only: no shell, so paths with spaces are safe.
sub first_line(@cmd) {
    my ( $in, $out );
    my $pid = eval { open3( $in, $out, undef, @cmd ) } or return;
    close $in;
    my @all = <$out>;
    waitpid $pid, 0;
    return $? ? undef : ( $all[0] // '' ) =~ s/\r?\n\z//r;
}

# Component-wise numeric version comparison: have >= min.
sub vge( $have, $min ) {
    my @h = split /\./, $have;
    my @m = split /\./, $min;
    for my $i ( 0 .. $#m ) {
        my ( $x, $y ) = ( $h[$i] // 0, $m[$i] );
        return $x > $y if $x != $y;
    }
    return 1;
}

sub write_file( $path, $text ) {
    make_path( $path =~ s{/[^/]+$}{}r );
    open my $fh, '>', $path or die "$path: $!\n";
    print $fh $text;
    close $fh;
}

# --- check ----------------------------------------------------------------

sub check {
    my $bad = 0;
    my $say = sub ( $st, $what, $detail ) {
        printf "check: %-5s %-12s %s\n", $st, $what, $detail;
        $bad++ if $st eq 'FAIL';
    };

    my @tools = (
        [ 'perl',     [qw(perl --version)],       '5.38' ],
        [ 'gcc',      [qw(gcc -dumpfullversion)], '13.0.0' ],
        [ 'g++',      [qw(g++ -dumpfullversion)], '13.0.0' ],
        [ 'cmake',    [qw(cmake --version)],      '3.28' ],
        [ 'ninja',    [qw(ninja --version)],      '1.10' ],
        [ 'cobc',     [qw(cobc --version)],       '3.1' ],
        [ 'dotnet',   [qw(dotnet --version)],     '10.0' ],
        [ 'python3',  [qw(python3 --version)],    '3.12' ],
        [ 'fpc',      [qw(fpc -iV)],              '3.2.2' ],
        [ 'lazbuild', [qw(lazbuild --version)],   '3.0' ],
        [ 'readelf',  [qw(readelf --version)],    '2.0' ],
        [ 'git',      [qw(git --version)],        '2.28' ],
    );

    for my $t (@tools) {
        my ( $label, $c, $min ) = @$t;
        my $line = first_line(@$c);
        my ($v) = defined $line ? $line =~ /(\d+(?:\.\d+)+)/ : ();
        if    ( !defined $v ) { $say->( 'FAIL', $label, 'not found' ) }
        elsif ( !vge( $v, $min ) ) {
            $say->( 'FAIL', $label, "$v (need >= $min)" );
        }
        else { $say->( 'ok', $label, $v ) }
    }

    my $cc = first_line( 'cob-config', '--version' );
    $say->(
        defined $cc ? 'ok' : 'warn',
        'cob-config', $cc // 'not found (needed to link ledger)'
    );

    for my $lib (qw(libstdc++.a libgcc.a libgcc_eh.a)) {
        my $p  = first_line( 'g++', "-print-file-name=$lib" ) // '';
        my $ok = $p =~ m{^/} && -f $p;
        $say->( $ok ? 'ok' : 'FAIL', $lib, $ok ? $p : 'not found' );
    }

    my $venv_py = "$root/.venv/bin/python3";
    my $py_ver =
      -x $venv_py
      ? first_line( $venv_py, '-c',
        'import PySide6; print(PySide6.__version__)' )
      : undef;

    if ( !defined $py_ver ) {
        $say->(
            'FAIL', 'PySide6', 'not importable in .venv; run: setup.pl venv'
        );
    }
    elsif ( !vge( $py_ver, '6.10.0' ) ) {
        $say->( 'FAIL', 'PySide6', "$py_ver (need >= 6.10.0)" );
    }
    else {
        $say->( 'ok', 'PySide6', $py_ver );
    }
    return $bad == 0 ? 0 : 1;
}

# --- venv -----------------------------------------------------------------

sub venv {
    my $dir = "$root/.venv";
    my $py  = "$dir/bin/python3";
    unless ( -x $py ) {
        system( 'python3', '-m', 'venv', $dir ) == 0
          or die
"venv: cannot create $dir (on Debian/Ubuntu: apt install python3-venv)\n";
        say 'venv: created .venv';
    }
    system( $py, '-m', 'pip', 'install', '--upgrade', 'PySide6>=6.10.0' ) == 0
      or die "venv: pip could not install PySide6 (network?)\n";
    say 'venv: PySide6 ready';
    return 0;
}

# --- init -----------------------------------------------------------------

sub init {
    if ( -d "$root/.git" ) {
        say 'init: failed (already a git repository)';
        return 1;
    }
    system( 'git', '-C', $root, 'init', '-q', '-b', 'main' ) == 0
      or die "git init failed\n";
    say 'init: git repository created (branch main)';

    my $p = "$root/.gitignore";
    unless ( -e $p ) {
        write_file( $p, <<~'EOT' );
            bin/
            build/
            dist/
            .venv/
            data/store/*
            data/backup/*
            ui/avalonia/bin/
            ui/avalonia/obj/
            ui/lazarus/lib/
            ui/lazarus/backup/
            ui/lazarus/link.inc
            __pycache__/
            EOT
    }
    return 0;
}

# --- clean ----------------------------------------------------------------

sub clean {
    GetOptions( 'all' => \my $all ) or die "usage: clean [--all]\n";

    my @trees =
      qw(build dist ui/avalonia/bin ui/avalonia/obj ui/lazarus/lib ui/lazarus/backup);
    push @trees, '.venv' if $all;
    remove_tree( map { "$root/$_" } @trees );
    unlink "$root/ui/lazarus/link.inc";

    if ( -d "$root/ui" ) {
        find(
            {
                no_chdir => 1,
                wanted   => sub {
                    if ( -d $_ && m{/__pycache__$} ) {
                        remove_tree($_);
                        $File::Find::prune = 1;
                    }
                    elsif ( -f $_ && m{\.(?:ppu|o|compiled)$} ) {
                        unlink $_;
                    }
                }
            },
            "$root/ui"
        );
    }
    if ($all) {
        for my $d (qw(store backup)) {
            opendir my $dh, "$root/data/$d" or next;
            for my $f ( readdir $dh ) {
                unlink "$root/data/$d/$f"
                  if -f "$root/data/$d/$f" && $f !~ /^\./;
            }
        }
    }
    say 'clean: done';
    return 0;
}
