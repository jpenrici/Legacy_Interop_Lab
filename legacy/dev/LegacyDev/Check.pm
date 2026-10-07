package LegacyDev::Check;
# legacy/dev/LegacyDev/Check.pm

=head1 NAME

LegacyDev::Check - what is installed, what is missing, what deviates

=head1 DESCRIPTION

Read-only. Looks at the machine and the tree, driven by the manifest in
C<LegacyDev::Components>, and prints one line per finding:

  [ OK ]  fine
  [WARN]  works, but differs from the project design (or is not built yet)
  [FAIL]  cannot build; the exit status of C<check> is 1

Deviations from the design (a system C<cobc>, GnuCOBOL 4.x, another GCC for
the generated C...) are warnings with the reason, measured when possible;
with C<set_strict(1)> they are failures. A final recommendation block shows
how to get the designed setup.

C<run_checks> returns the context the pipeline needs:

  { root, fails, cobol => {home,cobc,version,...}, cobol_cc, cc, cxx }

=cut

use strict;
use warnings;
use Exporter 'import';
use Cwd       qw(abs_path);
use LegacyDev qw(
  info can_run gcc_major capture_status os_release priv_describe priv_method child_perl
);
use LegacyDev::Components qw(legacy_root dev_dir components data_dirs);

our @EXPORT_OK = qw(run_checks cmd_check set_strict builders_in_sync);

my %SUPPORTED_COBOL = ( '3.1' => 1, '3.2' => 1 );
my @PERL_MODULES =
  qw(Digest::SHA File::Temp File::Find File::Path Getopt::Long Pod::Usage POSIX);

# Libraries that come with the C library: never bundled into lib/ (the same
# list as cobol/builder.pl).
my %CORE_LIBS = map { $_ => 1 }
  qw(linux-vdso libc libm libdl libpthread librt libgcc_s ld-linux-x86-64 ld-linux-aarch64);

my $STRICT = 0;    # --strict
my @DEVIATIONS;    # what differs from the project design (this run)
my %tally;         # ok / warn / fail counters (this run)

sub set_strict { $STRICT = $_[0] ? 1 : 0; return }

# ------------------------------------------------------------- entry points

sub cmd_check {
    my ($opt)     = @_;
    my $ctx       = run_checks($opt);
    my $installer = dev_dir() . '/gnucobol_install.pl';
    print "\n-- GnuCOBOL installs (gnucobol_install.pl status)\n";
    child_perl( $installer, {}, 'status' ) if -f $installer;
    return $ctx->{fails} ? 1 : 0;
}

# Runs every check; returns the context hash described above.
sub run_checks {
    my ($opt) = @_;
    %tally      = ();
    @DEVIATIONS = ();
    my %ctx = ( root => legacy_root() );

    info( 'project root: ' . legacy_root() );
    check_platform();

    for my $c ( components() ) {  # one section per component, from the manifest
        print "\n-- $c->{title}\n";
        my $tools = $c->{tools};
        check_cobol( \%ctx, $opt ) if $tools->{cobol};
        check_compiler( \%ctx, 'cc',  $tools->{cc},  $opt ) if $tools->{cc};
        check_compiler( \%ctx, 'cxx', $tools->{cxx}, $opt ) if $tools->{cxx};
    }

    check_build_tools();
    check_install_tools();
    check_project_files();
    check_build_state();

    print_recommendation() if @DEVIATIONS;

    $ctx{fails} = $tally{fail} // 0;
    printf "\n[legacy] %d ok, %d warning(s), %d failure(s)\n", $tally{ok} // 0,
      $tally{warn} // 0, $ctx{fails};
    return \%ctx;
}

# ---------------------------------------------------------------- reporting

# One entry of the report: level is ok | warn | fail. $hint may be a string or
# an array ref (one "->" line each).
sub report {
    my ( $level, $what, $detail, $hint ) = @_;
    $tally{$level}++;
    my %tag = ( ok => ' OK ', warn => 'WARN', fail => 'FAIL' );
    printf "[%s] %-20s %s\n", $tag{$level}, $what, $detail // '';
    if ( $hint && $level ne 'ok' ) {
        print "       -> $_\n" for ref $hint ? @$hint : $hint;
    }
    return;
}

# A deviation from the project design: WARN, or FAIL under --strict.
sub deviation {
    my ( $what, $detail, $hint ) = @_;
    push @DEVIATIONS, $what;
    my @h = ref $hint ? @$hint : ( $hint // () );
    push @h, 'treated as a failure because of --strict' if $STRICT;
    report( $STRICT ? 'fail' : 'warn', $what, $detail, \@h );
    return;
}

# Shown whenever the setup deviates from the project design.
sub print_recommendation {
    my %seen;
    my @what = grep { !$seen{$_}++ } @DEVIATIONS;
    my $dev  = dev_dir();
    print "\n-- recommendation\n";
    print <<"TXT";
Your setup is accepted, but it differs from the project design in: @{[ join ', ', @what ]}.
Designed setup:
  * GnuCOBOL 3.1.2 (verified) or 3.2, minimal build, in /opt/gnucobol-V
  * GCC 13 compiling the generated C; GCC >= 14 for the C bridge and the C++ extender
To get it (root is needed only for apt and /opt; see --priv):
  perl $dev/setup.pl prepare --gnucobol-version 3.1.2
Then compare both builds if you want proof the output is the same:
  md5sum data/store/cobol/cb_data.dat   (after building with each cobc)
TXT
    return;
}

# ------------------------------------------------------------------ checks

sub check_platform {
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
    my @missing_mod = grep { !eval "require $_; 1" } @PERL_MODULES;    ## no critic
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
    return;
}

# A GCC (C) or g++ (C++) of at least $spec->{min}, taken from the option or
# from the usual names.
sub check_compiler {
    my ( $ctx, $kind, $spec, $opt ) = @_;
    my @candidates =
        $opt->{ $spec->{option} } ? ( $opt->{ $spec->{option} } )
      : $kind eq 'cxx'            ? qw(g++-15 g++-14 g++)
      :                             qw(gcc-15 gcc-14 gcc);
    for my $cmd (@candidates) {
        my $major = gcc_major($cmd);
        next unless $major && $major >= $spec->{min};
        $ctx->{$kind} = $cmd;
        report( ok => $spec->{label}, "$cmd (GCC $major)" );
        return 1;
    }
    my $name = $kind eq 'cxx' ? 'g++' : 'GCC';
    report(
        fail => $spec->{label},
        "no $name >= $spec->{min} found",
        "apt install $spec->{apt}  (or: --$spec->{option} CMD)"
    );
    return 0;
}

# cmake (the highest version any component asks for), make, ldd.
sub check_build_tools {
    print "\n-- build tools\n";
    my ( $need, @who );
    for my $c ( components() ) {
        my $v = $c->{tools}{cmake} or next;
        push @who, $c->{name};
        $need = $v if !defined $need || version_ge( $v, $need );
    }
    if ( defined $need ) {
        if ( can_run('cmake') ) {
            my $v = cmake_version();
            if ( $v && version_ge( $v, $need ) ) { report( ok => 'cmake', $v ) }
            else {
                report(
                    fail => 'cmake',
                    ( $v // 'unknown version' ) . " (need >= $need)",
                    'apt install cmake  (needed by: '
                      . join( ', ', @who ) . ')'
                );
            }
        }
        else { report( fail => 'cmake', 'not found', 'apt install cmake' ) }
    }
    for my $tool (qw(make ldd)) {
        can_run($tool)
          ? report( ok => $tool, can_run($tool) )
          : report( fail => $tool, 'not found', 'apt install build-essential' );
    }
    return;
}

sub check_install_tools {
    print "\n-- tools used only to install GnuCOBOL\n";
    for my $tool (qw(curl gpg tar xz)) {
        can_run($tool)
          ? report( ok => $tool, can_run($tool) )
          : report( warn => $tool, 'not found', 'needed only by "prepare"' );
    }
    return;
}

sub check_project_files {
    print "\n-- project files\n";
    my $root     = legacy_root();
    my @required = map  { @{ $_->{requires} } } components();
    my @absent   = grep { !-f "$root/$_" } @required;
    if (@absent) {
        report(
            fail => 'sources and data',
            'missing: ' . join( ', ', @absent )
        );
    }
    else {
        report(
            ok => 'sources and data',
            scalar(@required) . ' required files present'
        );
    }

    my @nodir = grep { !-d "$root/$_" } data_dirs();
    @nodir
      ? report( warn => 'directories',
        "missing (created on build/run): @nodir" )
      : report( ok => 'directories', 'bin lib data/* present' );
    for my $d (qw(bin lib data/store/cobol)) {
        report(
            fail => "$d writable",
            'not writable by this user', 'fix the ownership of the tree'
        ) if -d "$root/$d" && !-w "$root/$d";
    }

    my ( $same, $detail ) = builders_in_sync();
    $same
      ? report( ok => 'builder helpers', $detail )
      : report(
        fail => 'builder helpers',
        $detail,
'the block between the shared-builder-helpers markers must be identical in every builder'
      );
    return;
}

sub check_build_state {
    print "\n-- build state\n";
    my $root = legacy_root();
    for my $c ( components() ) {
        for my $a ( @{ $c->{artifacts} } ) {
            if ( $a->{globs} ) {
                my @files = map { glob("$root/$_") } @{ $a->{globs} };
                @files
                  ? report(
                    ok => $a->{label},
                    join( ', ', map { s{.*/}{}r } @files )
                  )
                  : report(
                    warn => $a->{label},
                    $a->{missing} // 'not built yet', 'setup.pl build'
                  );
            }
            else {
                -x "$root/$a->{path}"
                  ? report( ok => $a->{label}, $a->{path} )
                  : report(
                    warn => $a->{label},
                    "$a->{path} not built yet", 'setup.pl build'
                  );
            }
        }
    }
    return;
}

# Every builder carries the same helper block between two markers; copies are
# the price of builders that work alone, and this keeps them from drifting.
sub builders_in_sync {
    my ( %block, @unreadable );
    for my $c ( components() ) {
        open( my $fh, '<', legacy_root() . "/$c->{builder}" )
          or do { push @unreadable, $c->{name}; next };
        local $/;
        my $text = <$fh>;
        close $fh;
        if ( $text =~
m{^# BEGIN shared-builder-helpers\n(.*?)^# END shared-builder-helpers\n}ms
          )
        {
            $block{ $c->{name} } = $1;
        }
        else { push @unreadable, $c->{name} }
    }
    return ( 0, 'no helper block in: ' . join( ', ', @unreadable ) )
      if @unreadable;

    my %groups;
    push @{ $groups{ $block{$_} } }, $_ for sort keys %block;
    return ( 1, 'identical in ' . scalar( keys %block ) . ' builders' )
      if keys %groups == 1;
    return ( 0,
        'differ: ' . join( ' | ', map { join( ',', @$_ ) } values %groups ) );
}

# ---------------------------------------------------------------- COBOL side

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

    my $found;
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

# What the libcob of this cobc would drag into lib/: its dependencies other
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

# The COBOL toolchain: which GnuCOBOL, where it came from, what its libcob
# would bring into lib/, and which C compiler it calls.
sub check_cobol {
    my ( $ctx,   $opt ) = @_;
    my ( $cobol, $err ) = find_cobol($opt);
    if ( !$cobol ) {
        report(
            fail => 'GnuCOBOL',
            $err,
            [
                'perl '
                  . dev_dir()
                  . '/setup.pl prepare   (installs the recommended one in /opt)',
                'or point to one: --cobol-home DIR / --system-cobol'
            ]
        );
        return 0;
    }
    $ctx->{cobol} = $cobol;
    check_cobol_version($cobol);
    check_cobol_origin($cobol);
    check_libcob_deps($cobol);
    check_cobol_compiler( $ctx, $cobol, $opt );
    return 1;
}

sub check_cobol_version {
    my ($cobol) = @_;
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
'only 3.1.2 is verified with this project (3.2 is expected to work)'
            ]
        );
    }
    return;
}

sub check_cobol_origin {
    my ($cobol) = @_;
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
    return;
}

# Measured, not assumed: what would be copied into lib/ ?
sub check_libcob_deps {
    my ($cobol) = @_;
    my $deps = libcob_deps( $cobol->{cobc} );
    if ( !$deps ) {
        report(
            warn => 'libcob dependencies',
            'could not locate libcob to assess it',
            'cobol/builder.pl will still check what it bundles'
        );
        return;
    }
    my @extra = grep { $_->{base} ne 'libgmp' } @$deps;
    if ( !@extra ) {
        report( ok => 'libcob dependencies', 'minimal: libgmp + libc only' );
        return;
    }
    my $mb = 0;
    $mb += $_->{size} for @extra;
    $mb = $mb / 1048576;
    my @names = map { $_->{base} } @extra;
    my $shown = join( ', ', @names > 8 ? ( @names[ 0 .. 7 ], '...' ) : @names );
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
    return;
}

# The C compiler cobc will call: the option, else gcc-13 when present, else
# whatever cobc was configured with.
sub check_cobol_compiler {
    my ( $ctx, $cobol, $opt ) = @_;
    my ( $rc, $info ) = capture_status( $cobol->{cobc}, '--info' );
    my ($default_cc) = $info =~ /^COB_CC\s*:\s*(\S+)/m;
    my $chosen = $opt->{'cobol-cc'}
      // ( gcc_major('gcc-13') ? 'gcc-13' : undef );
    $ctx->{cobol_cc} = $chosen;

    my $cc    = $chosen // $default_cc;
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
    return;
}

# ------------------------------------------------------------------ versions

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

1;
