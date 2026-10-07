package LegacyDev::Pipeline;
# legacy/dev/LegacyDev/Pipeline.pm

=head1 NAME

LegacyDev::Pipeline - build, run and clean the components, in dependency order

=head1 DESCRIPTION

Generic: it never names a component. For each one in the manifest it calls the
component's own builder through the common contract
C<builder.pl [all|build|test|clean]>, with the environment the manifest's
C<env> sub provides (the toolchain C<Check> found). It never does what a
builder does, and builders never need root, so neither does this module:
it refuses to build or run as root unless told C<allow_root(1)>, because the
files would end up owned by root.

C<prepare> is the only part that can need privileges; it delegates to
C<prepare_legacy_env.pl>, which asks for them itself (sudo, su, or a printed
command).

=cut

use strict;
use warnings;
use Exporter 'import';
use Cwd        qw(abs_path);
use File::Path qw(make_path);
use LegacyDev  qw(info warnx fatal step capture_status child_perl is_root);
use LegacyDev::Components
  qw(legacy_root dev_dir build_order data_dirs exit_meaning);
use LegacyDev::Check qw(run_checks);

our @EXPORT_OK = qw(cmd_prepare cmd_build cmd_run cmd_clean cmd_all allow_root);

# Libraries that come with the C library (not required to be inside lib/).
my %CORE_LIBS = map { $_ => 1 }
  qw(linux-vdso libc libm libdl libpthread librt libgcc_s ld-linux-x86-64 ld-linux-aarch64);

# Environment variables that could leak into the executables.
my @SCRUB_ENV =
  qw(LD_LIBRARY_PATH LD_PRELOAD COBOL_HOME LEGACY_HOME COB_CC COB_CFLAGS COB_LDFLAGS);

my $ALLOW_ROOT = 0;

sub allow_root { $ALLOW_ROOT = $_[0] ? 1 : 0; return }

# ------------------------------------------------------------------ guards

# Building or running as root leaves root-owned files in the tree.
sub guard_unprivileged {
    return 1 unless is_root();
    if ($ALLOW_ROOT) {
        warnx(
            'running as root (--allow-root): the files will be owned by root');
        return 1;
    }
    fatal(
        "refusing to build or run as root: the files would be owned by root.\n"
          . "[legacy] run as a normal user (no privilege is needed); --allow-root overrides, e.g. in a throw-away container"
    );
}

# What every builder gets besides its toolchain variables.
sub base_env { return $ALLOW_ROOT ? ( LEGACY_ALLOW_ROOT => 1 ) : () }

sub builder_path { return legacy_root() . "/$_[0]{builder}" }

# ----------------------------------------------------------------- prepare

# Installs missing tools: GnuCOBOL and the compilers (may need root).
sub cmd_prepare {
    my ($opt) = @_;
    my @a;
    push @a, '--gnucobol-version', $opt->{'gnucobol-version'}
      if $opt->{'gnucobol-version'};
    push @a, '--priv', $opt->{priv};
    push @a, '--root-owned' if $opt->{'root-owned'};
    push @a, '--no-check'   if defined $opt->{check} && !$opt->{check};
    push @a, '--yes'        if $opt->{yes};
    my $rc =
      child_perl( dev_dir() . '/prepare_legacy_env.pl', {}, 'install', @a );
    return $rc == 3 ? 3 : $rc ? 1 : 0;
}

# ------------------------------------------------------------------- build

sub cmd_build {
    my ( $opt, $ctx ) = @_;
    guard_unprivileged();
    $ctx //= run_checks($opt);
    if ( $ctx->{fails} ) {
        warnx(
'dependencies are missing; fix the FAIL lines above (or: setup.pl prepare)'
        );
        return 1;
    }
    make_path( map { legacy_root() . "/$_" } data_dirs() );

    my @order = build_order();
    my $n     = 0;
    for my $c (@order) {
        my %env       = ( %{ $c->{env}->($ctx) }, base_env() );
        my $toolchain = join ' ',
          map { "$_=$env{$_}" }
          grep { $_ ne 'LEGACY_ALLOW_ROOT' } sort keys %env;
        step( ++$n, scalar(@order),
            "$c->{title}: $c->{builder}"
              . ( $toolchain ? " ($toolchain)" : '' ) );
        child_perl( builder_path($c), \%env, 'build' ) == 0
          or fatal("$c->{builder} failed");
    }
    info('build finished');
    return 0;
}

# ------------------------------------------------------------------- clean

sub cmd_clean {
    guard_unprivileged();
    my $bad = 0;
    for my $c ( reverse build_order() ) {    # dependents first
        info("clean: $c->{builder}");
        $bad++ if child_perl( builder_path($c), { base_env() }, 'clean' ) != 0;
    }
    return $bad ? 1 : 0;
}

# --------------------------------------------------------------------- run

# Every run entry of the manifest, in build order, tagged with its component.
sub runnables {
    return map {
        my $c = $_;
        map {
            { %$_, component => $c->{name} }
        } @{ $c->{run} }
    } build_order();
}

# Every shared library of the executable, except the C library itself, must
# resolve inside legacy/lib (that is what makes the tree movable).
sub check_portability {
    my ($exe) = @_;
    my $root = legacy_root();
    local @ENV{@SCRUB_ENV};
    delete @ENV{@SCRUB_ENV};
    my ( $rc, $out ) =
      capture_status( '/bin/sh', '-c', 'cd "$1" && ldd "./$2" 2>&1',
        'sh', "$root/bin", $exe );
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
        push @bad, "$name -> $real" unless index( $real, "$root/lib/" ) == 0;
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
    my $bin = legacy_root() . '/bin';
    chdir $bin or fatal("chdir $bin: $!");
    open( my $fh, '-|', '/bin/sh', '-c', 'exec "$@" 2>&1', 'sh', "./$name" )
      or fatal("cannot start ./$name: $!");
    while (<$fh>) { print "    $_" }
    close $fh;
    return $? == -1 ? 127 : ( $? & 127 ) ? 128 + ( $? & 127 ) : $? >> 8;
}

# ok / warn / fail for one exit code, with a message.
sub judge_exit {
    my ( $entry, $rc ) = @_;
    my %meaning = exit_meaning();
    return ( 'ok',   'exit 0' ) if grep { $_ == $rc } @{ $entry->{ok} };
    return ( 'warn', "exit $rc: $entry->{warn}{$rc}" ) if $entry->{warn}{$rc};
    return ( 'fail', "exit $rc" . ( $meaning{$rc} ? ": $meaning{$rc}" : '' ) );
}

sub select_runnables {
    my ($names) = @_;
    my @all = runnables();
    return @all unless @$names;
    my %known   = map  { $_->{exe} => 1 } @all;
    my @unknown = grep { !$known{$_} } @$names;
    fatal(  "unknown executable(s): @unknown (known: "
          . join( ', ', map { $_->{exe} } @all )
          . ')' )
      if @unknown;
    my %want = map { $_ => 1 } @$names;
    return grep { $want{ $_->{exe} } } @all;
}

sub cmd_run {
    my ($names) = @_;
    guard_unprivileged();
    my @todo = select_runnables($names);

    my $root   = legacy_root();
    my @absent = grep { !-x "$root/bin/$_->{exe}" } @todo;
    if (@absent) {
        warnx(  'not built: '
              . join( ', ', map { "bin/$_->{exe}" } @absent )
              . ' - run: setup.pl build' );
        return 1;
    }
    make_path("$root/data/store/cobol");

    my ( @summary, $failed );
    my $n = 0;
    for my $e (@todo) {
        step( ++$n, scalar(@todo), "bin/$e->{exe}" );
        my ( $ok, $why ) = check_portability( $e->{exe} );
        printf "  portability: %s (%s)\n", $ok ? 'OK' : 'FAIL', $why;

        info("running from $root/bin with a clean environment");
        my ( $level, $msg ) = judge_exit( $e, run_exe( $e->{exe} ) );
        if ( !$ok ) {    # a portability failure outranks a good exit code
            $level = 'fail';
            $msg .= "; portability: $why";
        }
        $failed++ if $level eq 'fail';
        push @summary, [ $e->{exe}, uc $level, $msg ];
    }

    print "\n[legacy] summary\n";
    printf "  %-22s %-5s %s\n", @$_ for @summary;
    return $failed ? 1 : 0;
}

# --------------------------------------------------------------------- all

sub cmd_all {
    my ($opt) = @_;
    guard_unprivileged();
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

1;
