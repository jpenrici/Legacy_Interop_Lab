package LegacyDev::Components;
# legacy/dev/LegacyDev/Components.pm

=head1 NAME

LegacyDev::Components - the manifest: which components the project has

=head1 DESCRIPTION

The one place that knows the components of the project. C<Check> and
C<Pipeline> are generic: they read this list, so adding a component (the
Python bindings, a UI...) means adding one entry here, not editing them.

Each entry is a hash:

  name       short id, used in messages
  title      section title in the dependency report
  builder    path of its builder.pl, relative to the legacy root. Every
             builder honours the same contract: [all|build|test|clean],
             exit 0 = ok, never needs root, finds its tools from the
             environment variable(s) the C<env> sub provides
  depends    names of components that must be built first (build order is
             derived from it, and cycles are rejected)
  tools      what it needs, checked by C<Check>:
               cobol => 1                 a GnuCOBOL and the C compiler it calls
               cc    => { min, label, option, apt }    a GCC >= min (C)
               cxx   => { min, label, option, apt }    a g++ >= min (C++)
               cmake => 'X.Y'             CMake >= X.Y
  requires   source/data files that must exist
  artifacts  what the builder produces: { path, label }, or for a set of files
             { globs => [patterns], label, missing => 'text when absent' }
  run        executables that "setup.pl run" starts from legacy/bin, with the
             exit codes they may return: { exe, ok => [..], warn => {code=>why} }
  env        sub ($ctx) returning the environment variables its builder reads
             (the toolchain C<Check> found goes through here)

=head1 ADDING A COMPONENT

  {
      name => 'python', title => 'Python bindings',
      builder => 'bindings/python/builder.pl', depends => ['extender'],
      tools => { python => '3.9' },          # teach Check::check_tool about it
      requires  => [ 'bindings/python/pyproject.toml' ],
      artifacts => [ { path => 'bin/legacy_py_test', label => 'binding tests' } ],
      run       => [ { exe => 'legacy_py_test', ok => [0], warn => {} } ],
      env       => sub { { PYTHON => $_[0]{python} } },
  },

=cut

use strict;
use warnings;
use Exporter 'import';
use Cwd            qw(abs_path);
use File::Basename qw(dirname);

our @EXPORT_OK = qw(legacy_root dev_dir components component build_order
  data_dirs exit_meaning);

my $DEV  = abs_path( dirname(__FILE__) . '/..' );
my $ROOT = abs_path("$DEV/..");

sub dev_dir     { return $DEV }
sub legacy_root { return $ROOT }

# Directories the tree needs (created when missing).
sub data_dirs {
    return qw(bin lib data/input/cobol data/store/cobol data/backup);
}

# What the exit codes of cobol_app mean (shown when a run fails).
sub exit_meaning {
    return (
        1 => 'cannot open the input CSV',
        2 => 'cannot write the output .dat',
        3 => 'finished, some input lines were rejected',
        4 => 'amount overflow, run aborted',
    );
}

my @COMPONENTS = (
    {
        name     => 'cobol',
        title    => 'COBOL side',
        builder  => 'cobol/builder.pl',
        depends  => [],
        tools    => { cobol => 1 },
        requires => [
            'cobol/src/ledger.cob', 'cobol/builder.pl',
            'data/input/cobol/cb_data.csv'
        ],
        artifacts => [
            { path => 'bin/cobol_app', label => 'COBOL executable' },
            {
                globs   => [ 'lib/libcob.so.*', 'lib/libgmp.so.*' ],
                label   => 'bundled libs',
                missing => 'libcob/libgmp not in lib/ yet'
            },
        ],
        run => [
            {
                exe  => 'cobol_app',
                ok   => [0],
                warn => { 3 => 'some input lines were rejected' }
            }
        ],
        env => sub {
            my ($ctx) = @_;
            my %env;
            return \%env unless $ctx->{cobol};
            if ( $ctx->{cobol}{home} ) {
                $env{COBOL_HOME} = $ctx->{cobol}{home};
            }
            else { $env{COBC} = $ctx->{cobol}{cobc} }
            $env{COB_CC} = $ctx->{cobol_cc} if $ctx->{cobol_cc};
            return \%env;
        },
    },
    {
        name    => 'bridge',
        title   => 'C bridge',
        builder => 'bridge/builder.pl',
        depends => ['cobol'],
        tools   => {
            cc => {
                min    => 14,
                label  => 'bridge compiler',
                option => 'bridge-cc',
                apt    => 'gcc-14'
            },
            cmake => '3.16',
        },
        requires => [
            'bridge/builder.pl',    'bridge/CMakeLists.txt',
            'bridge/include/bridge.h', 'bridge/src/bridge.c',
            'bridge/tests/main.c'
        ],
        artifacts => [
            { path => 'bin/bridge_test',   label => 'bridge test program' },
            { path => 'lib/lib_c_api.so', label => 'bridge library' },
        ],
        run => [ { exe => 'bridge_test', ok => [0], warn => {} } ],
        env =>
          sub { my %e; $e{CC} = $_[0]{cc} if defined $_[0]{cc}; return \%e },
    },
    {
        name    => 'extender',
        title   => 'C++ extender',
        builder => 'extender/builder.pl',
        depends => ['bridge'],
        tools   => {
            cxx => {
                min    => 14,
                label  => 'extender compiler',
                option => 'extender-cxx',
                apt    => 'g++-14'
            },
            cmake => '3.25',
        },
        requires => [
            'extender/builder.pl',
            'extender/CMakeLists.txt',
            'extender/include/extender.h',
            'extender/include/extender.hpp',
            'extender/src/extender.cpp',
            'extender/src/extender_analytics.cpp',
            'extender/src/extender_ffi.cpp',
            'extender/tests/main.cpp'
        ],
        artifacts => [
            {
                path  => 'bin/extender_test',
                label => 'extender test program'
            },
            {
                path  => 'lib/lib_cpp_api.so',
                label => 'extender library'
            },
        ],
        run => [ { exe => 'extender_test', ok => [0], warn => {} } ],
        env =>
          sub { my %e; $e{CXX} = $_[0]{cxx} if defined $_[0]{cxx}; return \%e },
    },

    # Future (see "ADDING A COMPONENT" above): bindings/python, ui.
);

sub components { return @COMPONENTS }

sub component {
    my ($name) = @_;
    my ($c)    = grep { $_->{name} eq $name } @COMPONENTS;
    return $c;
}

# Components in an order where every one comes after what it depends on.
# Dies on an unknown dependency or a cycle.
sub build_order {
    my ( @order, %state );    # state: 1 = visiting, 2 = done
    my $visit;
    $visit = sub {
        my ($c) = @_;
        return if ( $state{ $c->{name} } // 0 ) == 2;
        die "dependency cycle through component '$c->{name}'\n"
          if ( $state{ $c->{name} } // 0 ) == 1;
        $state{ $c->{name} } = 1;
        for my $dep ( @{ $c->{depends} } ) {
            my $d = component($dep)
              or die "component '$c->{name}' depends on unknown '$dep'\n";
            $visit->($d);
        }
        $state{ $c->{name} } = 2;
        push @order, $c;
    };
    $visit->($_) for @COMPONENTS;
    return @order;
}

1;
